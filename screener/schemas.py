"""各阶段的结构化数据定义。

LLM 输出的模型会直接作为 structured outputs 的 schema，所以只用 str / int / float / bool /
list / Literal / 嵌套模型，不用 dict。
"""
from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel, Field

# ---------- Stage 1 · JD ----------

Level = Literal["must", "plus", "duty"]


class Requirement(BaseModel):
    id: str = Field(description="R01、R03a 这样的编号；职责用 D01")
    category: str = Field(description="experience / protocol / vendor / security / ops / language / soft / cert / other")
    text: str
    level: Level
    weight: int
    emphasized: bool = Field(description="原文是否加粗 / 强调")


class JDStruct(BaseModel):
    position: str
    location: str
    requirements: list[Requirement]


# ---------- Stage 2 · 简历 ----------


class ClaimedYears(BaseModel):
    value: float
    evidence_line: int


class Basic(BaseModel):
    name: str
    birth: Optional[str] = Field(description="YYYY-MM，简历没写就是 null")
    claimed_years: list[ClaimedYears]
    phone: list[str]
    email: list[str]


class Education(BaseModel):
    school: str
    degree: str
    major: str
    start: Optional[str]
    end: Optional[str]
    line: int


class Duty(BaseModel):
    text: str
    line: int


class Job(BaseModel):
    company: str
    title: str
    start: str = Field(description="YYYY-MM")
    end: Optional[str] = Field(description="YYYY-MM；至今则为 null")
    duties: list[Duty]
    line: int = Field(description="公司名所在行号")


class Project(BaseModel):
    name: str
    company: Optional[str]
    claimed_role: str = Field(description="简历原词：主导 / 负责 / 参与 / 未说明")
    details: list[str]
    lines: list[int]


class ResumeStruct(BaseModel):
    basic: Basic
    education: list[Education]
    jobs: list[Job]
    projects: list[Project]
    skills: list[str]
    certs: list[str]


# ---------- Stage 3 · 规则引擎（代码生成，不给 LLM） ----------


class Flag(BaseModel):
    code: str
    severity: Literal["high", "medium", "low"]
    message: str
    evidence_lines: list[int] = []


# ---------- Stage 4 · 匹配 ----------

Verdict = Literal["match", "partial", "missing", "unknown"]


class Evidence(BaseModel):
    line: int
    quote: str = Field(description="简历原文片段，逐字摘抄")


class MatchItem(BaseModel):
    req_id: str
    verdict: Verdict
    evidence: list[Evidence]
    reason: str
    interview_focus: bool


class MatchResult(BaseModel):
    items: list[MatchItem]


# ---------- Stage 5 · 疑点 ----------


class Doubt(BaseModel):
    id: str = Field(description="S 开头，如 S01")
    type: str
    severity: Literal["high", "medium", "low"]
    title: str
    evidence: list[Evidence]
    verify_question: str
    source: Literal["rule", "llm"] = "llm"


class DoubtResult(BaseModel):
    doubts: list[Doubt]


# ---------- Stage 6 · 题目 ----------

Section = Literal["背景核实", "项目深挖", "核心能力", "缺口场景", "软性要求"]
SECTION_ORDER: list[str] = ["背景核实", "项目深挖", "核心能力", "缺口场景", "软性要求"]


class QSource(BaseModel):
    type: Literal["resume", "jd", "doubt"]
    lines: list[int]
    quote: str = Field(description="type=resume 时必须是简历原文；jd 填要求原文；doubt 填疑点标题")


class Rubric(BaseModel):
    excellent: str
    pass_: str = Field(alias="pass")
    fail: str

    model_config = {"populate_by_name": True}


class Question(BaseModel):
    id: str
    section: Section
    minutes: int
    question: str
    source: QSource
    linked_requirements: list[str]
    linked_doubts: list[str]
    answer_points: list[str]
    key_points: list[str] = Field(description="必须出现的关键要点，是 answer_points 的子集")
    follow_ups: list[str]
    red_flags: list[str]
    rubric: Rubric


class QuestionSet(BaseModel):
    questions: list[Question]


# ---------- Stage 7 · 结论 ----------

Decision = Literal["advance", "conditional", "reject"]
DECISION_LABEL = {"advance": "推进", "conditional": "有条件推进", "reject": "不推荐"}


class ConclusionText(BaseModel):
    summary: str
    must_verify: list[str]
    pass_signals: list[str]
    fail_signals: list[str]
    hard_fail: bool = Field(description="是否存在明确不满足的硬性条件（例如岗位要求的证件/地点）")


class Conclusion(ConclusionText):
    decision: Decision
    score: float
    veto: list[str]


# ---------- 面试后评价 ----------


class Evaluation(BaseModel):
    decision: Literal["通过", "待定", "不通过"]
    comment: str


class QuestionReview(BaseModel):
    question_id: str
    covered: list[str] = Field(description="候选人答到的参考答案要点")
    missed: list[str] = Field(description="没答到的要点，尤其是关键要点")
    red_flags_hit: list[str] = Field(description="踩中的红旗信号，没有就留空")
    suggested_score: Literal["excellent", "pass", "fail", "not_asked"]
    evidence: str = Field(description="逐字稿里最能说明问题的一句候选人原话，没问到留空")


class DoubtCheck(BaseModel):
    doubt: str
    result: Literal["已澄清", "仍存疑", "未问到"]
    note: str


class InterviewSummary(BaseModel):
    decision: Literal["通过", "待定", "不通过"]
    comment: str = Field(description="口语化面试评价，150 字以内，可直接贴进招聘系统")
    highlights: list[str]
    concerns: list[str]
    doubts: list[DoubtCheck]
    questions: list[QuestionReview]


# ---------- 汇总 ----------


class Report(BaseModel):
    position: str
    candidate: str
    interview_minutes: int
    jd: JDStruct
    resume: ResumeStruct
    flags: list[Flag]
    match: list[MatchItem]
    doubts: list[Doubt]
    questions: list[Question]
    conclusion: Conclusion
    validation: list[str] = Field(default_factory=list, description="校验层日志")
    round: int = 1                                       # 第几轮面试
    carry_over: list[str] = Field(default_factory=list)  # 上一轮遗留、这一轮要重点核实的事
    model_meta: list[dict] = Field(default_factory=list)


class QuestionNote(BaseModel):
    note: str = Field(description="面试官备注口吻的本题表现总结，80 字以内")


class LiveHint(BaseModel):
    covered: list[str]
    missing: list[str]
    follow_up: str = Field(description="下一句可以直接问的追问，没有就留空")
    flags: list[str]


class CandidateCompare(BaseModel):
    name: str
    strengths: list[str]
    risks: list[str]


class CompareResult(BaseModel):
    recommendation: str
    ranking: list[str]
    per_candidate: list[CandidateCompare]
