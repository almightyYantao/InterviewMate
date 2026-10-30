"""匹配分、一票否决、结论判定——全部由代码完成，保证同等条件下结论一致。"""
from __future__ import annotations

from . import config
from .schemas import Decision, Doubt, JDStruct, MatchItem


def _cfg() -> dict:
    return config.get()["scoring"]


def score(match: list[MatchItem], jd: JDStruct) -> float:
    w = {r.id: r.weight for r in jd.requirements if r.level != "duty"}
    v = _cfg()
    num = sum(w.get(m.req_id, 0) * v[m.verdict] for m in match)
    den = sum(w.get(m.req_id, 0) for m in match)
    return round(num / den * 10, 1) if den else 0.0


def vetoes(match: list[MatchItem], jd: JDStruct) -> list[str]:
    reqs = {r.id: r for r in jd.requirements}
    return [m.req_id for m in match
            if m.verdict == "missing" and (r := reqs.get(m.req_id))
            and r.level == "must" and r.weight >= _cfg()["veto_weight"]]


def decide(s: float, veto: list[str], doubts: list[Doubt], hard_fail: bool = False) -> Decision:
    highs = sum(d.severity == "high" for d in doubts)
    c = _cfg()
    if hard_fail or s < c["reject"]:
        return "reject"
    if s >= c["advance"] and not veto and highs <= c["max_high_doubts"]:
        return "advance"
    return "conditional"
