"""面试后口语化评价。"""
from __future__ import annotations

import json

from .llm import OPUS, SONNET, call_structured, prompt
from .schemas import Evaluation, CompareResult, InterviewSummary, LiveHint, QuestionNote, Report

LABEL = {"excellent": "优秀", "pass": "合格", "fail": "不合格", "skip": "跳过（没问）"}


def generate(report: Report, scores: list[dict], overall_note: str = "", meta: list[dict] | None = None) -> Evaluation:
    """scores: [{question_id, score, note}]"""
    qs = {q.id: q for q in report.questions}
    rows = []
    for s in scores:
        q = qs.get(s["question_id"])
        if not q:
            continue
        rows.append({"题目": q.question, "环节": q.section, "打分": LABEL.get(s.get("score") or "", "未打分"),
                     "备注": s.get("note") or ""})
    doubts = [{"疑点": d.title, "级别": d.severity} for d in report.doubts if d.severity != "low"]
    user = (f"岗位：{report.position}\n<scores>\n{json.dumps(rows, ensure_ascii=False, indent=1)}\n</scores>\n"
            f"<doubts>\n{json.dumps(doubts, ensure_ascii=False, indent=1)}\n</doubts>\n"
            f"<overall_note>\n{overall_note}\n</overall_note>")
    ev = call_structured(stage="evaluation", model=SONNET, system=prompt("evaluation"), user=user,
                         schema=Evaluation, effort="medium", meta=meta)
    return ev


def summarize(report: Report, scores: list[dict], transcript: list[dict], overall_note: str = "",
              meta: list[dict] | None = None) -> InterviewSummary:
    """transcript: [{speaker: me/candidate, text, question_id, at}]"""
    sc = {s["question_id"]: s for s in scores}
    qs = [{"id": q.id, "题目": q.question, "环节": q.section, "参考答案要点": q.answer_points,
           "关键要点": q.key_points, "红旗信号": q.red_flags,
           "评分标准": {"优秀": q.rubric.excellent, "合格": q.rubric.pass_, "不合格": q.rubric.fail},
           "面试官打分": LABEL.get((sc.get(q.id) or {}).get("score") or "", "未打分"),
           "面试官备注": (sc.get(q.id) or {}).get("note") or ""} for q in report.questions]
    doubts = [{"疑点": d.title, "级别": d.severity, "核实问题": d.verify_question} for d in report.doubts]
    lines = []
    for u in transcript:
        at = int(u.get("at") or 0)
        sp = u.get("speaker")
        who = {"me": "面试官", "mark_good": "面试官标记·亮点", "mark_doubt": "面试官标记·存疑"}.get(sp, "候选人")
        lines.append(f"[{at // 60:02d}:{at % 60:02d}][{u.get('question_id') or '-'}] {who}：{u.get('text', '')}")
    user = (f"岗位：{report.position}\n<questions>\n{json.dumps(qs, ensure_ascii=False, indent=1)}\n</questions>\n"
            f"<doubts>\n{json.dumps(doubts, ensure_ascii=False, indent=1)}\n</doubts>\n"
            f"<transcript>\n" + "\n".join(lines) + "\n</transcript>\n"
            f"<overall_note>\n{overall_note}\n</overall_note>")
    return call_structured(stage="summary", model=OPUS, system=prompt("summary"), user=user,
                           schema=InterviewSummary, effort="high", meta=meta)


def question_note(report: Report, question_id: str, transcript: list[dict]) -> str:
    q = next((x for x in report.questions if x.id == question_id), None)
    if not q or not transcript:
        return ""
    lines = "\n".join(f"{ {'me': '面试官', 'mark_good': '面试官标记·亮点', 'mark_doubt': '面试官标记·存疑'}.get(u.get('speaker'), '候选人')}：{u.get('text', '')}" for u in transcript)
    user = (f"<question>\n{q.question}\n参考答案要点：{json.dumps(q.answer_points, ensure_ascii=False)}\n"
            f"红旗信号：{json.dumps(q.red_flags, ensure_ascii=False)}\n</question>\n<transcript>\n{lines}\n</transcript>")
    return call_structured(stage="question_note", model=SONNET, system=prompt("question_note"), user=user,
                           schema=QuestionNote, effort="low", max_tokens=4000).note


def live_hint(report: Report, question_id: str, transcript: list[dict]) -> LiveHint:
    q = next((x for x in report.questions if x.id == question_id), None)
    if not q:
        return LiveHint(covered=[], missing=[], follow_up="", flags=[])
    key = set(q.key_points)
    pts = [("★ " if p in key else "") + p for p in q.answer_points]
    lines = "\n".join(f"{ {'me': '面试官', 'mark_good': '面试官标记·亮点', 'mark_doubt': '面试官标记·存疑'}.get(u.get('speaker'), '候选人')}：{u.get('text', '')}" for u in transcript[-30:])
    user = (f"<question>\n{q.question}\n参考答案要点：{json.dumps(pts, ensure_ascii=False)}\n"
            f"红旗信号：{json.dumps(q.red_flags, ensure_ascii=False)}\n追问：{json.dumps(q.follow_ups, ensure_ascii=False)}\n"
            f"</question>\n<transcript>\n{lines}\n</transcript>")
    return call_structured(stage="live_hint", model=SONNET, system=prompt("live_hint"), user=user,
                           schema=LiveHint, effort="low", max_tokens=2000)


def compare(rows: list[dict], position: str) -> CompareResult:
    user = f"岗位：{position}\n<candidates>\n{json.dumps(rows, ensure_ascii=False, indent=1)}\n</candidates>"
    return call_structured(stage="compare", model=SONNET, system=prompt("compare"), user=user,
                           schema=CompareResult, effort="medium", max_tokens=8000)
