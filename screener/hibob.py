"""HiBob 招聘模块（Bob Hiring）对接：只读。拉在招岗位 + JD、面试安排、候选人。

HiBob 的 Hiring API 目前没有写入接口，面试反馈不能自动回写，界面上提供按格式复制。
文档：https://apidocs.hibob.com/docs/explore-hiring-api
"""
from __future__ import annotations

import html
import re

import httpx

from . import config


class HiBobError(RuntimeError):
    pass


def _base() -> str:
    return "https://api.sandbox.hibob.com/v1" if config.get()["hibob_sandbox"] else "https://api.hibob.com/v1"


def configured() -> bool:
    c = config.get()
    return bool(c["hibob_user_id"] and c["hibob_token"])


def my_id() -> str:
    """我在 HiBob 里的员工 ID：设置里填了就用，否则用邮箱查一次并缓存。"""
    c = config.get()
    if c["hibob_employee_id"]:
        return str(c["hibob_employee_id"])
    if not c["hibob_email"]:
        raise HiBobError("请在设置 › HiBob 里填写你自己的 HiBob 邮箱，用来只显示你参与的面试")
    with httpx.Client(timeout=30, auth=(c["hibob_user_id"], c["hibob_token"])) as cl:
        r = cl.post(f"{_base()}/people/search", headers={"Accept": "application/json"}, json={
            "fields": ["root.id", "root.email", "root.displayName"],
            "filters": [{"fieldPath": "root.email", "operator": "equals", "values": [c["hibob_email"]]}]})
    if r.status_code >= 400:
        raise HiBobError(f"用邮箱查员工 ID 失败（{r.status_code}）。可以在设置里直接填员工 ID：{r.text[:120]}")
    emps = r.json().get("employees") or []
    eid = emps and (emps[0].get("id") or (emps[0].get("root") or {}).get("id"))
    if not eid:
        raise HiBobError("HiBob 里没找到这个邮箱对应的员工；Service User 需要能查看员工基本信息，或者在设置里直接填员工 ID")
    config.save({"hibob_employee_id": str(eid)})
    return str(eid)


def search(entity: str, fields: list[str], filters: list[dict] | None = None, limit_total: int = 2000) -> list[dict]:
    """POST /hiring/{entity}/search，自动翻页。返回 {字段ID: 值} 列表。"""
    c = config.get()
    if not configured():
        raise HiBobError("还没有填 HiBob 的 Service User ID 和 Token")
    out, cursor = [], None
    with httpx.Client(timeout=30, auth=(c["hibob_user_id"], c["hibob_token"])) as cl:
        while True:
            body = {"fields": fields, "filters": filters or [], "limit": 200}
            if cursor:
                body["cursor"] = cursor
            r = cl.post(f"{_base()}/hiring/{entity}/search", json=body, headers={"Accept": "application/json"})
            if r.status_code == 401:
                raise HiBobError("HiBob 认证失败：Service User ID 或 Token 不对")
            if r.status_code == 403:
                raise HiBobError("HiBob 拒绝访问：Service User 需要「Manage all job openings」权限，且公司要开通 Bob Hiring")
            if r.status_code >= 400:
                raise HiBobError(f"HiBob 返回 {r.status_code}：{r.text[:200]}")
            d = r.json()
            out += d.get("items", [])
            cursor = (d.get("response_metadata") or {}).get("next_cursor")
            if not cursor or len(out) >= limit_total:
                return out


def _ids_filter(field: str, ids: list) -> list[dict]:
    return [{"fieldId": field, "operator": "equals", "values": list(ids)}]


def _text(h: str | None) -> str:
    """HTML 描述转纯文本，保留段落和列表"""
    if not h:
        return ""
    h = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</h\d>", "\n", h)
    h = re.sub(r"(?i)<li[^>]*>", "\n- ", h)
    h = re.sub(r"<[^>]+>", "", h)
    return re.sub(r"\n{3,}", "\n\n", html.unescape(h)).strip()


def openings() -> list[dict]:
    """只返回和我有关的岗位：我有面试安排的，或者我是招聘负责人 / Owner 的"""
    me = my_id()
    mine = {i["job_opening_id"] for i in interviews()}
    jo = [o for o in search("job-openings", ["/jobOpening/id", "/jobOpening/title", "/jobOpening/status",
                                             "/jobOpening/department", "/jobOpening/createdAt",
                                             "/jobOpening/recruiterId", "/jobOpening/owner"])
          if str(o["/jobOpening/id"]) in mine or me in (str(o.get("/jobOpening/recruiterId")), str(o.get("/jobOpening/owner")))]
    ads = search("job-ads", ["/jobAd/id", "/jobAd/jobOpeningId", "/jobAd/description",
                             "/jobAd/responsibilities", "/jobAd/requirements"])
    jd: dict = {}
    for a in ads:
        parts = [("岗位描述", a.get("/jobAd/description")), ("岗位职责", a.get("/jobAd/responsibilities")),
                 ("任职要求", a.get("/jobAd/requirements"))]
        jd.setdefault(str(a.get("/jobAd/jobOpeningId")), "\n\n".join(f"{t}\n{_text(v)}" for t, v in parts if _text(v)))
    return [{"id": str(o["/jobOpening/id"]), "title": o.get("/jobOpening/title") or "",
             "status": o.get("/jobOpening/status") or "", "department": str(o.get("/jobOpening/department") or ""),
             "jd": jd.get(str(o["/jobOpening/id"]), "")} for o in jo]


def interviews() -> list[dict]:
    """我当面试官的面试安排 + 候选人姓名"""
    me = my_id()
    iv = [i for i in search("interviews", ["/interview/id", "/interview/name", "/interview/title", "/interview/status",
                                           "/interview/startAt", "/interview/endAt", "/interview/applicationId",
                                           "/interview/jobOpeningId", "/interview/conferencing",
                                           "/interview/hasEvaluation", "/interview/interviewers"])
          if any(str(p.get("id")) == me for p in (i.get("/interview/interviewers") or []) if isinstance(p, dict))]
    app_ids = sorted({i["/interview/applicationId"] for i in iv if i.get("/interview/applicationId")})
    apps = search("applications", ["/application/id", "/application/candidateId", "/application/status"],
                  _ids_filter("/application/id", app_ids)) if app_ids else []
    cand_of = {a["/application/id"]: a.get("/application/candidateId") for a in apps}
    cand_ids = sorted({v for v in cand_of.values() if v})
    cands = search("candidates", ["/candidate/id", "/candidate/firstName", "/candidate/lastName", "/candidate/email"],
                   _ids_filter("/candidate/id", cand_ids)) if cand_ids else []
    by_id = {c["/candidate/id"]: c for c in cands}
    out = []
    for i in iv:
        cand = by_id.get(cand_of.get(i.get("/interview/applicationId")), {})
        name = f'{cand.get("/candidate/lastName") or ""}{cand.get("/candidate/firstName") or ""}'.strip()
        if name and re.search(r"[A-Za-z]", name):
            name = f'{cand.get("/candidate/firstName") or ""} {cand.get("/candidate/lastName") or ""}'.strip()
        conf = i.get("/interview/conferencing")
        out.append({"id": str(i["/interview/id"]), "title": i.get("/interview/title") or i.get("/interview/name") or "",
                    "status": i.get("/interview/status") or "", "start_at": i.get("/interview/startAt"),
                    "end_at": i.get("/interview/endAt"), "job_opening_id": str(i.get("/interview/jobOpeningId") or ""),
                    "candidate_name": name, "candidate_email": cand.get("/candidate/email") or "",
                    "has_evaluation": bool(i.get("/interview/hasEvaluation")),
                    "meeting_url": conf.get("url") if isinstance(conf, dict) else (conf if isinstance(conf, str) else "")})
    out.sort(key=lambda x: x["start_at"] or "")
    return out
