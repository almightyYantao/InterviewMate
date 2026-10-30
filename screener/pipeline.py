"""Stage 0 ~ 8 编排。"""
from __future__ import annotations

import hashlib
import json
from concurrent.futures import ThreadPoolExecutor
from datetime import date
from pathlib import Path
from typing import Callable

from . import config, rules, scoring, verify
from .llm import OPUS, SONNET, call_structured, prompt
from .parsing import Doc
from .schemas import (
    Conclusion, ConclusionText, Doubt, DoubtResult, Evidence, Flag, JDStruct, MatchItem, MatchResult,
    Question, QuestionSet, Report, ResumeStruct, SECTION_ORDER,
)

CACHE_DIR = Path(__file__).resolve().parent.parent / ".cache" / "jd"

DEFAULT_CONTEXT = ""   # 公司环境描述在「设置」里填，见 config.company_ctx

Progress = Callable[[str], None]


def _dump(m) -> str:
    return json.dumps(m.model_dump(by_alias=True) if hasattr(m, "model_dump") else m, ensure_ascii=False, indent=1)


# ---------- Stage 1 ----------


def structure_jd(jd: Doc, meta: list[dict], use_cache: bool = True) -> JDStruct:
    marked = "\n".join(f"【加粗】{l}" if i + 1 in jd.bold_lines else l for i, l in enumerate(jd.lines))
    key = hashlib.sha256((config.get()["ai_language"] + marked).encode()).hexdigest()[:16]
    path = CACHE_DIR / f"{key}.json"
    if use_cache and path.exists():
        meta.append({"stage": "jd", "cached": True})
        res = JDStruct.model_validate_json(path.read_text())
    else:
        res = call_structured(stage="jd", model=SONNET, system=prompt("jd"), user=f"<jd>\n{marked}\n</jd>",
                              schema=JDStruct, effort="medium", meta=meta)
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        path.write_text(res.model_dump_json(indent=1))
    # weight 规则由代码兜底，按设置里的默认权重
    w = config.get()["weights"]
    for r in res.requirements:
        r.weight = w[r.level] + (w["emphasis"] if r.emphasized else 0)
    return res


# ---------- Stage 2 ----------


def structure_resume(doc: Doc, meta: list[dict]) -> ResumeStruct:
    user = f"<resume>\n{doc.numbered()}\n</resume>"
    if doc.scanned:
        user = "简历是扫描版，文字层不可用，请直接阅读附带的 PDF；行号按你读到的行顺序从 1 编号。\n" + user
    return call_structured(stage="resume", model=SONNET, system=prompt("resume"), user=user,
                           schema=ResumeStruct, effort="medium", pdf=doc.pdf_bytes, meta=meta)


# ---------- Stage 4 ----------


def match(jd: JDStruct, doc: Doc, today: date, meta: list[dict]) -> list[MatchItem]:
    reqs = [r for r in jd.requirements if r.level != "duty"]
    user = f"<jd>\n{_dump([r.model_dump() for r in reqs])}\n</jd>\n<resume>\n{doc.numbered()}\n</resume>"
    res = call_structured(stage="match", model=SONNET, system=prompt("match", today=today.isoformat()),
                          user=user, schema=MatchResult, effort="high", meta=meta)
    return res.items


# ---------- Stage 5 ----------


def flags_to_doubts(flags: list[Flag], doc: Doc) -> list[Doubt]:
    out = []
    verify_q = {
        "YEARS_MISMATCH": "简历里写了两个不同的工作年限，以哪个为准？第一份正式工作是哪一年开始的？",
        "EDU_MISSING": "简历没写教育经历，最高学历、学校、专业和毕业时间是？是全日制吗？",
        "EARLY_START": "第一份工作开始时学业是否已经完成？学历是全日制还是在职取得？",
        "GAP": "这段空窗期在做什么？",
        "OVERLAP": "这两段经历时间重叠，是兼职还是交接期？",
        "CURRENT_GAP": "离职多久了？离职原因是什么？最快多久可以到岗？",
        "JOB_HOPPING": "这几段经历时间都不长，离开的原因分别是什么？",
        "CONTACT_FORMAT": "（无需提问，核对联系方式即可）",
        "DUPLICATE_CONTENT": "同一个项目在简历里出现了两次，描述的是同一件事吗？",
        "FORMAT_MESS": "（无需提问，弱信号）",
    }
    for i, f in enumerate(flags, 1):
        evs = [Evidence(line=n, quote=doc.lines[n - 1]) for n in f.evidence_lines if 1 <= n <= len(doc.lines)]
        out.append(Doubt(id=f"F{i:02d}", type=f.code, severity=f.severity, title=f.message, evidence=evs,
                         verify_question=verify_q.get(f.code, "请候选人说明。"), source="rule"))
    return out


def semantic_doubts(resume: ResumeStruct, doc: Doc, flags: list[Flag], today: date, meta: list[dict]) -> list[Doubt]:
    user = (f"今天是 {today.isoformat()}。\n<rule_flags>\n{_dump([f.model_dump() for f in flags])}\n</rule_flags>\n"
            f"<resume_struct>\n{_dump(resume)}\n</resume_struct>\n<resume>\n{doc.numbered()}\n</resume>")
    res = call_structured(stage="doubts", model=OPUS, system=prompt("doubts"), user=user,
                          schema=DoubtResult, effort="high", meta=meta)
    for d in res.doubts:
        d.source = "llm"
    return res.doubts


# ---------- Stage 6 ----------


def _q_context(jd, doc, match_items, doubts, company_ctx) -> str:
    return (f"<company_context>\n{company_ctx}\n</company_context>\n"
            f"<jd>\n{_dump(jd)}\n</jd>\n<resume>\n{doc.numbered()}\n</resume>\n"
            f"<match>\n{_dump([m.model_dump() for m in match_items])}\n</match>\n"
            f"<doubts>\n{_dump([d.model_dump() for d in doubts if d.type not in ('CONTACT_FORMAT', 'FORMAT_MESS')])}\n</doubts>")


def _complete(q: Question) -> bool:
    """模型偶尔返回残缺题目（题干或参考答案为空），这种题不能用"""
    return bool(q.question.strip()) and len(q.answer_points) >= 2 and bool(q.rubric.pass_.strip())


PREV_RULES = """

【这是第 {round} 轮面试】输入里的 <previous_rounds> 是前面几轮的结论和遗留问题：
- 前几轮已经问清楚、表现确定的内容不要再问；
- 优先出题核实 <previous_rounds> 里「仍存疑 / 没问到 / 答得不好 / 遗留」的点，每个遗留点至少一道题覆盖；
- 题目可以比上一轮更深，侧重场景和实际动手；
- source.type 为 doubt 的题，source.quote 写对应的遗留点原文。"""


def gen_questions(jd, doc, match_items, doubts, company_ctx, minutes, meta, previous: str = "", round_no: int = 1) -> list[Question]:
    best: list[Question] = []
    for _ in range(2):
        res = call_structured(stage="questions", model=OPUS,
                              system=prompt("questions", position=jd.position, minutes=minutes)
                              + (PREV_RULES.format(round=round_no) if previous else ""),
                              user=_q_context(jd, doc, match_items, doubts, company_ctx)
                              + (f"\n<previous_rounds>\n{previous}\n</previous_rounds>" if previous else ""),
                              schema=QuestionSet, effort="high", meta=meta)
        good = [q for q in res.questions if _complete(q)]
        if len(good) > len(best):
            best = good
        if len(good) >= 6 and len(good) == len(res.questions):
            break
    return best


def fill_questions(jd, doc, match_items, doubts, company_ctx, existing, miss_d, miss_r, meta) -> list[Question]:
    unc = {"doubts": [d.model_dump() for d in miss_d], "requirements": [m.model_dump() for m in miss_r]}
    user = (_q_context(jd, doc, match_items, doubts, company_ctx)
            + f"\n<existing>\n{_dump([q.question for q in existing])}\n</existing>\n<uncovered>\n{_dump(unc)}\n</uncovered>")
    res = call_structured(stage="questions_fill", model=OPUS,
                          system=prompt("questions_fill", position=jd.position, next_id=f"Q{len(existing) + 1:02d}"),
                          user=user, schema=QuestionSet, effort="high", meta=meta)
    return [q for q in res.questions if _complete(q)]


# ---------- Stage 7 ----------


def conclude(jd, match_items, doubts, meta) -> Conclusion:
    s = scoring.score(match_items, jd)
    veto = scoring.vetoes(match_items, jd)
    pre = scoring.decide(s, veto, doubts)
    reqs = {r.id: r.text for r in jd.requirements}
    brief = {
        "decision": pre, "score": s, "veto": [f"{v} {reqs.get(v, '')}" for v in veto],
        "match": [{"req": reqs.get(m.req_id, m.req_id), "verdict": m.verdict, "reason": m.reason} for m in match_items],
        "doubts": [{"severity": d.severity, "title": d.title} for d in doubts],
    }
    txt = call_structured(stage="conclusion", model=SONNET, system=prompt("conclusion"),
                          user=f"<decision>\n{_dump(brief)}\n</decision>", schema=ConclusionText,
                          effort="medium", meta=meta)
    final = scoring.decide(s, veto, doubts, hard_fail=txt.hard_fail)
    return Conclusion(**txt.model_dump(), decision=final, score=s, veto=veto)


# ---------- 编排 ----------


def run(jd_doc: Doc, resume_doc: Doc, *, company_ctx: str = DEFAULT_CONTEXT, minutes: int = 60,
        today: date | None = None, progress: Progress = print, jd_struct: JDStruct | None = None) -> Report:
    today = today or date.today()
    meta: list[dict] = []
    log: list[str] = []
    lines = resume_doc.lines

    progress("Stage 1-2 · JD 与简历结构化（并行）")
    with ThreadPoolExecutor(2) as ex:
        f_jd = ex.submit(lambda: jd_struct or structure_jd(jd_doc, meta))
        f_rs = ex.submit(structure_resume, resume_doc, meta)
        jd, resume = f_jd.result(), f_rs.result()

    progress("Stage 3 · 规则引擎")
    flags = rules.run_all(resume, resume_doc, today)

    progress("Stage 4-5 · JD 匹配 + 语义疑点（并行）")
    with ThreadPoolExecutor(2) as ex:
        f_m = ex.submit(match, jd, resume_doc, today, meta)
        f_d = ex.submit(semantic_doubts, resume, resume_doc, flags, today, meta)
        match_items, sem = f_m.result(), f_d.result()

    progress("Stage 8a · 证据校验")
    match_items = verify.check_match(match_items, jd, lines, log)
    doubts = flags_to_doubts(flags, resume_doc) + verify.check_doubts(sem, lines, log)

    progress("Stage 6 · 生成面试题与参考答案（Opus，约 1~2 分钟）")
    with ThreadPoolExecutor(1) as ex:  # 结论与出题互不依赖，结论放后台
        f_c = ex.submit(conclude, jd, match_items, doubts, meta)
        qs = gen_questions(jd, resume_doc, match_items, doubts, company_ctx, minutes, meta)
        progress("Stage 8b · 题目校验 / 覆盖率 / 去重 / 时长")
        qs = verify.check_question_sources(qs, lines, log)
        miss_d, miss_r = verify.uncovered(qs, doubts, match_items, jd)
        if miss_d or miss_r:
            log.append(f"[覆盖] 未覆盖：疑点 {[d.id for d in miss_d]}，缺口 {[m.req_id for m in miss_r]}，补题")
            progress("Stage 6b · 补题")
            extra = fill_questions(jd, resume_doc, match_items, doubts, company_ctx, qs, miss_d, miss_r, meta)
            qs += verify.check_question_sources(extra, lines, log)
            miss_d, miss_r = verify.uncovered(qs, doubts, match_items, jd)
            if miss_d or miss_r:
                log.append(f"[覆盖] 补题后仍未覆盖：疑点 {[d.id for d in miss_d]}，缺口 {[m.req_id for m in miss_r]}")
        qs = verify.dedupe(qs, log)
        qs = verify.fit_duration(qs, minutes, doubts, jd, match_items, log)
        progress("Stage 7 · 结论")
        conclusion = f_c.result()

    return Report(position=jd.position, candidate=resume.basic.name, interview_minutes=minutes, jd=jd,
                  resume=resume, flags=flags, match=match_items, doubts=doubts, questions=qs,
                  conclusion=conclusion, validation=log, model_meta=meta)


def regenerate_questions(report: Report, resume_doc: Doc, company_ctx: str = DEFAULT_CONTEXT,
                         progress: Progress = print, previous: str = "", carry: list[str] | None = None) -> Report:
    """只重跑 Stage 6 + 8b。previous 不为空时是出下一轮的题：轮次 +1，带上前几轮的遗留。"""
    meta, log = list(report.model_meta), list(report.validation)
    jd, lines = report.jd, resume_doc.lines
    rnd = report.round + 1 if previous else report.round
    progress(f"Stage 6 · 生成第 {rnd} 轮面试题" if previous else "Stage 6 · 重新出题")
    qs = gen_questions(jd, resume_doc, report.match, report.doubts, company_ctx, report.interview_minutes, meta,
                       previous=previous or _carry_text(report), round_no=rnd)
    qs = verify.check_question_sources(qs, lines, log)
    miss_d, miss_r = verify.uncovered(qs, report.doubts, report.match, jd)
    if miss_d or miss_r:
        qs += verify.check_question_sources(
            fill_questions(jd, resume_doc, report.match, report.doubts, company_ctx, qs, miss_d, miss_r, meta), lines, log)
    qs = verify.fit_duration(verify.dedupe(qs, log), report.interview_minutes, report.doubts, jd, report.match, log)
    upd = {"questions": qs, "model_meta": meta, "validation": log}
    if previous:
        upd.update(round=rnd, carry_over=carry or [])
    return report.model_copy(update=upd)


def _carry_text(report: Report) -> str:
    """重新出某一轮的题时，沿用这一轮已有的遗留点"""
    return "\n".join(f"- {x}" for x in report.carry_over) if report.round > 1 else ""


__all__ = ["run", "regenerate_questions", "DEFAULT_CONTEXT", "SECTION_ORDER"]
