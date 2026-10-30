from datetime import date
from pathlib import Path

import pytest

from screener import parsing, rules, scoring, verify
from screener.schemas import (
    Basic, ClaimedYears, Doubt, Evidence, JDStruct, Job, MatchItem, Project, Question, QSource,
    Requirement, ResumeStruct, Rubric,
)

FIX = Path(__file__).resolve().parent.parent / "fixtures" / "input"
TODAY = date(2026, 10, 30)


def job(company, start, end, line=1):
    return Job(company=company, title="工程师", start=start, end=end, duties=[], line=line)


def lxp_resume(**kw) -> ResumeStruct:
    """示例简历的关键字段（附录 B 测试用例）。"""
    d = dict(
        basic=Basic(name="候选人甲", birth="1992-11", phone=[], email=["www.candidate@example.com"],
                    claimed_years=[ClaimedYears(value=16, evidence_line=4), ClaimedYears(value=13, evidence_line=8)]),
        education=[],
        jobs=[job("杭州盈盈", "2021-10", "2026-07", 15), job("浙江海淘云", "2020-07", "2021-10", 50),
              job("每日互动", "2018-07", "2020-06", 60), job("托宝", "2017-05", "2018-06", 90),
              job("同伟", "2013-04", "2017-04", 100)],
        projects=[Project(name="核心网络架构升级", company="每日互动", claimed_role="负责", details=[], lines=[70]),
                  Project(name="大型 IDC 核心网络架构升级", company=None, claimed_role="负责", details=[], lines=[120])],
        skills=[], certs=["H3C TE"],
    )
    d.update(kw)
    return ResumeStruct(**d)


def codes(flags):
    return [f.code for f in flags]


def test_lxp_timeline():
    flags = rules.check_timeline(lxp_resume(), TODAY)
    by = {f.code: f for f in flags}
    assert {"YEARS_MISMATCH", "EDU_MISSING", "EARLY_START", "CURRENT_GAP"} <= set(by)
    assert "13.5 年" in by["YEARS_MISMATCH"].message and by["YEARS_MISMATCH"].severity == "high"
    assert "20.4" in by["EARLY_START"].message
    assert "3 个月" in by["CURRENT_GAP"].message
    assert "GAP" not in by and "OVERLAP" not in by and "JOB_HOPPING" not in by


def test_gap_overlap_hopping():
    r = lxp_resume(jobs=[job("A", "2020-01", "2020-06"), job("B", "2020-12", "2021-08"), job("C", "2021-06", None)],
                   education=[], basic=Basic(name="x", birth=None, phone=[], email=[], claimed_years=[]))
    c = codes(rules.check_timeline(r, TODAY))
    assert c.count("GAP") == 1 and c.count("OVERLAP") == 1 and "JOB_HOPPING" in c and "CURRENT_GAP" not in c


def test_consistent_years_no_flag():
    r = lxp_resume(basic=Basic(name="x", birth=None, phone=[], email=[],
                               claimed_years=[ClaimedYears(value=13, evidence_line=1)]))
    assert "YEARS_MISMATCH" not in codes(rules.check_timeline(r, TODAY))


# 真实简历含个人信息，不进仓库；本地放了 fixtures/input/resume_lxp.pdf 才跑这两个测试
needs_pdf = pytest.mark.skipif(not (FIX / "resume_lxp.pdf").exists(), reason="需要本地示例简历 PDF")


@needs_pdf
def test_contact_and_duplicates_on_real_pdf():
    doc = parsing.load(FIX / "resume_lxp.pdf")
    r = lxp_resume(basic=Basic(name="候选人甲", birth="1992-11", phone=[], email=[], claimed_years=[]))
    c = codes(rules.check_contact(r, doc))
    assert c == ["CONTACT_FORMAT"]
    assert "DUPLICATE_CONTENT" in codes(rules.check_duplicates(r, doc))
    cdn = lxp_resume(projects=[Project(name="常州电信 CDN 节点建设：900G", company=None, claimed_role="负责", details=[], lines=[109]),
                               Project(name="嘉兴电信 CDN 节点建设：600G", company=None, claimed_role="负责", details=[], lines=[110])])
    assert not [f for f in rules.check_duplicates(cdn, doc) if "CDN" in f.message]


@needs_pdf
def test_parse_pdf_watermark_and_mask():
    doc = parsing.load(FIX / "resume_lxp.pdf")
    assert "cc20541b" not in doc.clean_text
    assert "工作年限： 16 年" in doc.clean_text
    phone = next(v for k, v in doc.pii.items() if k.startswith("[手机"))
    assert phone not in doc.clean_text and "[手机_1]" in doc.clean_text
    assert not doc.scanned


def test_watermark_token_removal():
    wm = "cc20541b8719e34f03R709S0EFdQxYq7V"
    out = parsing.remove_watermark_tokens([f"a {wm}", f"{wm} b", f"c{wm}", "www.example-very-long-domain-name.com"])
    assert all(wm not in l for l in out) and out[3].startswith("www.")


def test_verify_quote():
    lines = ["负责三墩机房核心网络升级项目：", "将原有大二层网络架构升级为大三层网络架构；"]
    assert verify.verify_quote("将原有大二层网络架构升级为大三层网络架构", lines, [5]) == 2
    assert verify.verify_quote("负责 FortiGate 防火墙策略", lines, [1]) is None


def jd():
    return JDStruct(position="网络工程师", location="杭州", requirements=[
        Requirement(id="R01", category="experience", text="5 年", level="must", weight=3, emphasized=False),
        Requirement(id="R04a", category="vendor", text="Fortinet", level="must", weight=5, emphasized=True),
        Requirement(id="P01", category="cert", text="CCNP", level="plus", weight=1, emphasized=False),
    ])


def test_score_and_veto():
    m = [MatchItem(req_id="R01", verdict="match", evidence=[], reason="", interview_focus=False),
         MatchItem(req_id="R04a", verdict="missing", evidence=[], reason="", interview_focus=True),
         MatchItem(req_id="P01", verdict="unknown", evidence=[], reason="", interview_focus=False)]
    s = scoring.score(m, jd())
    assert s == pytest.approx((3 * 1 + 5 * 0 + 1 * 0.3) / 9 * 10, abs=0.05)
    assert scoring.vetoes(m, jd()) == ["R04a"]
    assert scoring.decide(9.0, ["R04a"], []) == "conditional"
    assert scoring.decide(9.0, [], []) == "advance"
    assert scoring.decide(4.9, [], []) == "reject"
    high = [Doubt(id=f"S{i}", type="x", severity="high", title="t", evidence=[], verify_question="q") for i in range(2)]
    assert scoring.decide(9.0, [], high) == "conditional"


def test_match_without_evidence_downgraded():
    log: list[str] = []
    m = [MatchItem(req_id="R01", verdict="match", evidence=[Evidence(line=1, quote="编造的内容")], reason="", interview_focus=False)]
    out = verify.check_match(m, jd(), ["真实的第一行"], log)
    assert out[0].verdict == "unknown" and len(out) == 3  # R04a / P01 漏判补 unknown
    assert any("降级" in x for x in log)


def q(id, section, minutes, reqs=(), doubts=()):
    return Question(id=id, section=section, minutes=minutes, question=f"问题{id}",
                    source=QSource(type="jd", lines=[], quote=""), linked_requirements=list(reqs),
                    linked_doubts=list(doubts), answer_points=[], key_points=[], follow_ups=[], red_flags=[],
                    rubric=Rubric(excellent="", pass_="", fail=""))


def test_coverage_and_duration():
    m = [MatchItem(req_id="R04a", verdict="missing", evidence=[], reason="", interview_focus=True)]
    d = [Doubt(id="F01", type="EDU_MISSING", severity="high", title="t", evidence=[], verify_question="q")]
    qs = [q("Q1", "核心能力", 30), q("Q2", "软性要求", 30)]
    miss_d, miss_r = verify.uncovered(qs, d, m, jd())
    assert [x.id for x in miss_d] == ["F01"] and [x.req_id for x in miss_r] == ["R04a"]

    qs = [q("Q1", "背景核实", 10, doubts=["F01"]), q("Q2", "缺口场景", 20, reqs=["R04a"]),
          q("Q3", "核心能力", 25), q("Q4", "软性要求", 20)]
    out = verify.fit_duration(qs, 60, d, jd(), m, log := [])
    assert sum(x.minutes for x in out) <= 65
    kept = {x.question for x in out}
    assert "问题Q1" in kept and "问题Q2" in kept and "问题Q4" not in kept
    assert [x.id for x in out] == [f"Q{i:02d}" for i in range(1, len(out) + 1)]
