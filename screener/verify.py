"""Stage 8 · 校验层：证据存在性、覆盖率、去重、时长。"""
from __future__ import annotations

import re

from rapidfuzz import fuzz

from .schemas import Doubt, Evidence, JDStruct, MatchItem, Question, SECTION_ORDER

QUOTE_THRESHOLD = 90


def _norm(s: str) -> str:
    return re.sub(r"\s+", "", s).strip("…. ")


def verify_quote(quote: str, lines: list[str], line_hint: list[int]) -> int | None:
    """返回匹配到的行号（1 起）；先在提示行号 ±1 范围内找，找不到再全文搜索。"""
    q = _norm(quote)
    if len(q) < 2:
        return None
    hint = sorted({h + d for h in line_hint for d in (0, -1, 1) if 1 <= h + d <= len(lines)})
    for span in (1, 2):  # 先单行，再允许引文跨两行
        for pool in (hint, range(1, len(lines) + 1)):
            for no in pool:
                t = _norm("".join(lines[no - 1: no - 1 + span]))
                if q in t or (8 <= len(q) <= len(t) + 4 and fuzz.partial_ratio(q, t) >= QUOTE_THRESHOLD):
                    return no
    return None


def _fix_evidence(evs: list[Evidence], lines: list[str], log: list[str], where: str) -> list[Evidence]:
    out = []
    for e in evs:
        no = verify_quote(e.quote, lines, [e.line])
        if no is None:
            log.append(f"[证据] {where}：删除无法在简历中找到的引文「{e.quote[:40]}」")
            continue
        if no != e.line:
            log.append(f"[证据] {where}：行号 {e.line} → {no}")
        out.append(Evidence(line=no, quote=e.quote))
    return out


def check_match(items: list[MatchItem], jd: JDStruct, lines: list[str], log: list[str]) -> list[MatchItem]:
    reqs = [r for r in jd.requirements if r.level != "duty"]
    by_id = {i.req_id: i for i in items}
    out = []
    for r in reqs:
        it = by_id.get(r.id)
        if it is None:
            log.append(f"[匹配] {r.id} 模型漏判，记为 unknown")
            out.append(MatchItem(req_id=r.id, verdict="unknown", evidence=[], reason="模型未给出判断", interview_focus=True))
            continue
        it.evidence = _fix_evidence(it.evidence, lines, log, it.req_id)
        if it.verdict in ("match", "partial") and not it.evidence:
            log.append(f"[匹配] {it.req_id} 判为 {it.verdict} 但没有有效证据，降级为 unknown")
            it.verdict = "unknown"
            it.reason = f"（原判断无有效原文证据，已降级）{it.reason}"
            it.interview_focus = True
        if it.verdict in ("missing", "unknown") and it.evidence:
            it.evidence = []
        out.append(it)
    return out


def check_doubts(doubts: list[Doubt], lines: list[str], log: list[str]) -> list[Doubt]:
    out = []
    for d in doubts:
        if d.source == "rule":
            out.append(d)
            continue
        d.evidence = _fix_evidence(d.evidence, lines, log, d.id)
        if not d.evidence:
            log.append(f"[疑点] {d.id}「{d.title}」没有有效原文证据，已删除")
            continue
        out.append(d)
    return out


def check_question_sources(qs: list[Question], lines: list[str], log: list[str]) -> list[Question]:
    out = []
    for q in qs:
        if q.source.type == "resume":
            no = verify_quote(q.source.quote, lines, q.source.lines)
            if no is None:
                if q.section == "项目深挖":
                    log.append(f"[题目] {q.id} 项目深挖题引文不在简历中，已删除：「{q.source.quote[:40]}」")
                    continue
                log.append(f"[题目] {q.id} 引文不在简历中，来源改标为 JD/疑点")
                q.source.type = "doubt" if q.linked_doubts else "jd"
            else:
                q.source.lines = [no]
        out.append(q)
    return out


def uncovered(qs: list[Question], doubts: list[Doubt], match: list[MatchItem], jd: JDStruct) -> tuple[list[Doubt], list[MatchItem]]:
    linked_d = {d for q in qs for d in q.linked_doubts}
    linked_r = {r for q in qs for r in q.linked_requirements}
    weights = {r.id: r.weight for r in jd.requirements}
    levels = {r.id: r.level for r in jd.requirements}
    miss_d = [d for d in doubts if d.severity == "high" and d.id not in linked_d]
    miss_r = [m for m in match if m.verdict in ("missing", "partial") and weights.get(m.req_id, 0) >= 3
              and levels.get(m.req_id) == "must" and m.req_id not in linked_r]
    return miss_d, miss_r


def dedupe(qs: list[Question], log: list[str]) -> list[Question]:
    """文档写的是 embedding 相似度；这里用字符级相似度近似，避免额外依赖。"""
    out: list[Question] = []
    for q in qs:
        dup = next((p for p in out if fuzz.token_set_ratio(p.question, q.question) > 90), None)
        if dup:
            log.append(f"[去重] {q.id} 与 {dup.id} 重复，已删除")
            dup.linked_doubts = sorted(set(dup.linked_doubts) | set(q.linked_doubts))
            dup.linked_requirements = sorted(set(dup.linked_requirements) | set(q.linked_requirements))
            continue
        out.append(q)
    return out


def _priority(q: Question, protected: set[str]) -> int:
    """数字越大越先被删除。"""
    if q.id in protected:
        return -1
    return {"软性要求": 4, "核心能力": 3, "项目深挖": 2, "缺口场景": 1, "背景核实": 0}[q.section]


def fit_duration(qs: list[Question], minutes: int, doubts: list[Doubt], jd: JDStruct,
                 match: list[MatchItem], log: list[str]) -> list[Question]:
    qs = sorted(qs, key=lambda q: SECTION_ORDER.index(q.section))
    # 保护题：唯一覆盖某个 high 疑点 / weight≥3 缺口的题
    protected: set[str] = set()
    weights = {r.id: r.weight for r in jd.requirements}
    gaps = {m.req_id for m in match if m.verdict in ("missing", "partial") and weights.get(m.req_id, 0) >= 3}
    highs = {d.id for d in doubts if d.severity == "high"}
    for key in list(gaps) + list(highs):
        cover = [q for q in qs if key in q.linked_requirements or key in q.linked_doubts]
        if len(cover) == 1:
            protected.add(cover[0].id)

    total = sum(q.minutes for q in qs)
    while total > minutes + 5:
        cand = sorted(qs, key=lambda q: (_priority(q, protected), q.minutes))
        victim = cand[-1]
        if _priority(victim, protected) < 0:
            # 只剩保护题，按比例压缩时长
            scale = minutes / total
            for q in qs:
                q.minutes = max(2, round(q.minutes * scale))
            log.append(f"[时长] 全部为必保题，按比例压缩到约 {sum(q.minutes for q in qs)} 分钟")
            break
        qs.remove(victim)
        total -= victim.minutes
        log.append(f"[时长] 超时，删除 {victim.id}（{victim.section}，{victim.minutes} 分钟）")
    if total < minutes - 5 and qs:
        extra = minutes - total
        deep = [q for q in qs if q.section in ("项目深挖", "缺口场景")] or qs
        # 每题最多加到 12 分钟；题太少时宁可留出空余时间，也不把一道题拉得很长
        added = 0
        for _ in range(extra):
            room = [q for q in deep if q.minutes < 12]
            if not room:
                break
            min(room, key=lambda q: q.minutes).minutes += 1
            added += 1
        log.append(f"[时长] 不足，给深挖/场景题追加 {added} 分钟" + (f"，仍差 {extra - added} 分钟" if added < extra else ""))
    # 重新编号
    for i, q in enumerate(qs, 1):
        q.id = f"Q{i:02d}"
    return qs
