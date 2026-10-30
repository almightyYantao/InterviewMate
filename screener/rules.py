"""Stage 3 · 规则引擎：确定性计算，不调用大模型。"""
from __future__ import annotations

import re
from datetime import date

from rapidfuzz import fuzz

from .parsing import Doc
from .schemas import Flag, ResumeStruct


def parse_ym(s: str | None) -> date | None:
    if not s:
        return None
    m = re.match(r"^\s*(\d{4})\D*(\d{1,2})?", s)
    if not m:
        return None
    return date(int(m.group(1)), int(m.group(2) or 1), 1)


def months_between(a: date, b: date) -> int:
    return (b.year - a.year) * 12 + (b.month - a.month)


def fmt(d: date) -> str:
    return f"{d.year}-{d.month:02d}"


def check_timeline(resume: ResumeStruct, today: date) -> list[Flag]:
    flags: list[Flag] = []
    jobs = [j for j in resume.jobs if parse_ym(j.start)]
    jobs.sort(key=lambda j: parse_ym(j.start))
    claimed = resume.basic.claimed_years
    claimed_lines = [c.evidence_line for c in claimed]

    # 1. 自述年限 vs 计算年限
    if jobs:
        first = parse_ym(jobs[0].start)
        computed = months_between(first, today) / 12
        values = sorted({c.value for c in claimed})
        if len(values) > 1 or any(abs(v - computed) > 1.5 for v in values):
            flags.append(Flag(
                code="YEARS_MISMATCH", severity="high",
                message=f"自述 {', '.join(f'{v:g}' for v in values)} 年，按首份工作（{fmt(first)}）计算约 {computed:.1f} 年",
                evidence_lines=claimed_lines + [jobs[0].line],
            ))

    # 2. 学历缺失
    if not resume.education:
        flags.append(Flag(code="EDU_MISSING", severity="high", message="简历未提供教育经历"))

    # 3. 首份工作时的年龄（仅用于时间线自洽校验，不参与评分）
    birth = parse_ym(resume.basic.birth)
    if birth and jobs:
        age = months_between(birth, parse_ym(jobs[0].start)) / 12
        if age < 21.5:
            flags.append(Flag(
                code="EARLY_START", severity="medium",
                message=f"首份工作开始时约 {age:.1f} 岁，需核实学历形式或是否在读（出生日期仅用于时间线校验）",
                evidence_lines=[jobs[0].line],
            ))

    # 4. 经历之间的空窗与重叠
    for prev, cur in zip(jobs, jobs[1:]):
        pe, cs = parse_ym(prev.end), parse_ym(cur.start)
        if not pe or not cs:
            continue
        gap = months_between(pe, cs)
        if gap > 3:
            flags.append(Flag(code="GAP", severity="medium",
                              message=f"{fmt(pe)} ~ {fmt(cs)} 空窗 {gap} 个月（{prev.company} → {cur.company}）",
                              evidence_lines=[prev.line, cur.line]))
        if gap < 0:
            flags.append(Flag(code="OVERLAP", severity="medium",
                              message=f"{prev.company} 与 {cur.company} 时间重叠 {-gap} 个月",
                              evidence_lines=[prev.line, cur.line]))

    # 5. 当前空窗
    if jobs and jobs[-1].end:
        last_end = parse_ym(jobs[-1].end)
        if last_end and months_between(last_end, today) >= 2:
            flags.append(Flag(code="CURRENT_GAP", severity="low",
                              message=f"{fmt(last_end)} 离职至今 {months_between(last_end, today)} 个月",
                              evidence_lines=[jobs[-1].line]))

    # 6. 跳槽频率
    short = [j for j in jobs if j.end and parse_ym(j.end)
             and months_between(parse_ym(j.start), parse_ym(j.end)) < 12]
    if len(short) >= 2:
        flags.append(Flag(code="JOB_HOPPING", severity="medium",
                          message=f"{len(short)} 段经历不满 1 年：{'、'.join(j.company for j in short)}",
                          evidence_lines=[j.line for j in short]))
    return flags


_EMAIL_OK = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")


def check_contact(resume: ResumeStruct, doc: Doc) -> list[Flag]:
    flags = []
    emails = list(resume.basic.email) + [v for k, v in doc.pii.items() if k.startswith("[邮箱")]
    for e in dict.fromkeys(doc.pii.get(x, x) for x in emails):
        if e.lower().startswith("www.") or not _EMAIL_OK.match(e):
            flags.append(Flag(code="CONTACT_FORMAT", severity="low",
                              message=f"邮箱格式异常：{e}", evidence_lines=_find_lines(doc, e)))
    return flags


def _find_lines(doc: Doc, s: str) -> list[int]:
    masked = next((k for k, v in doc.pii.items() if v == s), s)
    return [i + 1 for i, l in enumerate(doc.lines) if s in l or masked in l]


def check_duplicates(resume: ResumeStruct, doc: Doc) -> list[Flag]:
    flags = []
    seen: set[tuple[int, int]] = set()
    # 行级重复
    cand = [(i, l) for i, l in enumerate(doc.lines) if len(l) >= 12]
    for a in range(len(cand)):
        for b in range(a + 1, len(cand)):
            (i, x), (j, y) = cand[a], cand[b]
            if j - i < 3:
                continue
            if fuzz.ratio(x, y) > 85:
                seen.add((i + 1, j + 1))
                flags.append(Flag(code="DUPLICATE_CONTENT", severity="low",
                                  message=f"内容重复：「{x[:30]}」", evidence_lines=[i + 1, j + 1]))
    # 项目级重复
    ps = resume.projects
    for a in range(len(ps)):
        for b in range(a + 1, len(ps)):
            if re.findall(r"\d+", ps[a].name) != re.findall(r"\d+", ps[b].name):
                continue  # 「常州 900G」和「嘉兴 600G」是不同项目
            if fuzz.partial_ratio(ps[a].name, ps[b].name) >= 85 or fuzz.token_set_ratio(ps[a].name, ps[b].name) >= 85:
                la, lb = (ps[a].lines or [0])[0], (ps[b].lines or [0])[0]
                if (la, lb) in seen:
                    continue
                flags.append(Flag(code="DUPLICATE_CONTENT", severity="low",
                                  message=f"项目重复出现：「{ps[a].name}」与「{ps[b].name}」",
                                  evidence_lines=[x for x in (la, lb) if x]))
    return flags


def check_format(doc: Doc) -> list[Flag]:
    if doc.format_mess >= 0.6:
        return [Flag(code="FORMAT_MESS", severity="low",
                     message=f"编号格式混用（混乱度 {doc.format_mess}），可能是多份简历拼接")]
    return []


def run_all(resume: ResumeStruct, doc: Doc, today: date | None = None) -> list[Flag]:
    today = today or date.today()
    return (check_timeline(resume, today) + check_contact(resume, doc)
            + check_duplicates(resume, doc) + check_format(doc))
