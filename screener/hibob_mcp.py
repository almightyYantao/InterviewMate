"""用个人 Bob 账号连接 HiBob 官方 MCP（OAuth + PKCE，动态注册客户端）。

地址和认证元数据：https://mcp.hibob.com/.well-known/oauth-authorization-server
只能看到你本人在 Bob 里有权限看的数据。Token 有效 30 天，过期后用 refresh_token 续，续不了就重新登录。
"""
from __future__ import annotations

import base64
import hashlib
import json
import secrets
import time
from urllib.parse import urlencode

import httpx

from . import config

BASE = "https://mcp.hibob.com"
MCP_URL = f"{BASE}/mcp/public"
SCOPE = "mcp:tools:read mcp:tools:execute"
_pending: dict[str, dict] = {}     # state → {verifier, client_id, redirect_uri}


class MCPError(RuntimeError):
    pass


def _tok() -> dict:
    return config.get().get("hibob_oauth") or {}


def connected() -> bool:
    return bool(_tok().get("refresh_token") or _tok().get("access_token"))


def login_url(redirect_uri: str) -> str:
    r = httpx.post(f"{BASE}/oauth/register", timeout=20, json={
        "client_name": "面搭子", "redirect_uris": [redirect_uri], "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"], "token_endpoint_auth_method": "none", "scope": SCOPE})
    if r.status_code >= 400:
        raise MCPError(f"注册 Bob 客户端失败：{r.status_code} {r.text[:200]}")
    client_id = r.json()["client_id"]
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    _pending[state] = {"verifier": verifier, "client_id": client_id, "redirect_uri": redirect_uri}
    return f"{BASE}/oauth/authorize?" + urlencode({
        "response_type": "code", "client_id": client_id, "redirect_uri": redirect_uri, "scope": SCOPE,
        "state": state, "code_challenge": challenge, "code_challenge_method": "S256", "resource": MCP_URL})


def _save(d: dict, client_id: str) -> None:
    old = _tok()
    config.save({"hibob_oauth": {
        "access_token": d["access_token"], "refresh_token": d.get("refresh_token") or old.get("refresh_token", ""),
        "expires_at": time.time() + int(d.get("expires_in") or 3600) - 60, "client_id": client_id,
        "user": old.get("user", "")}})


def finish_login(state: str, code: str) -> None:
    p = _pending.pop(state, None)
    if not p:
        raise MCPError("登录已过期，请在 App 里重新点「用 Bob 账号登录」")
    r = httpx.post(f"{BASE}/oauth/token", timeout=20, data={
        "grant_type": "authorization_code", "code": code, "redirect_uri": p["redirect_uri"],
        "client_id": p["client_id"], "code_verifier": p["verifier"], "resource": MCP_URL})
    if r.status_code >= 400:
        raise MCPError(f"换取令牌失败：{r.status_code} {r.text[:200]}")
    _save(r.json(), p["client_id"])


def logout() -> None:
    config.save({"hibob_oauth": {}})


def _access() -> str:
    t = _tok()
    if not t:
        raise MCPError("还没有用 Bob 账号登录")
    if t.get("access_token") and time.time() < t.get("expires_at", 0):
        return t["access_token"]
    r = httpx.post(f"{BASE}/oauth/token", timeout=20, data={
        "grant_type": "refresh_token", "refresh_token": t.get("refresh_token", ""), "client_id": t.get("client_id", ""),
        "resource": MCP_URL})
    if r.status_code >= 400:
        logout()
        raise MCPError("Bob 登录已过期，请重新登录")
    _save(r.json(), t.get("client_id", ""))
    return _tok()["access_token"]


def _rpc(cl: httpx.Client, headers: dict, method: str, params: dict | None, rid: int | None) -> tuple[dict | None, httpx.Response]:
    body = {"jsonrpc": "2.0", "method": method, "params": params or {}}
    if rid is not None:
        body["id"] = rid
    r = cl.post(MCP_URL, json=body, headers=headers)
    if r.status_code == 401:
        raise MCPError("Bob 登录已失效，请重新登录")
    if r.status_code >= 400:
        raise MCPError(f"Bob MCP 返回 {r.status_code}：{r.text[:200]}")
    if rid is None or not r.content:
        return None, r
    text = r.text
    if "text/event-stream" in r.headers.get("content-type", ""):
        datas = [l[5:].strip() for l in text.splitlines() if l.startswith("data:")]
        msgs = [json.loads(d) for d in datas if d]
        msg = next((m for m in msgs if m.get("id") == rid), msgs[-1] if msgs else {})
    else:
        msg = r.json()
    if "error" in msg:
        raise MCPError(f"Bob MCP 错误：{msg['error'].get('message')}")
    return msg.get("result"), r


def _pick(d: dict, *keys: str) -> str:
    """字段名不固定：按关键字找第一个有值的字段（支持嵌套 dict 里的 name / title / url）"""
    for k, v in d.items():
        if any(x.lower() in k.lower() for x in keys) and v not in (None, "", [], {}):
            if isinstance(v, dict):
                v = v.get("displayName") or v.get("name") or v.get("title") or v.get("url") or v.get("value") or ""
            if isinstance(v, (str, int, float)):
                return str(v)
    return ""


def my_interviews() -> list[dict]:
    """我是面试官的面试，转成界面用的格式"""
    r = call("myInterviews_getMyInterviews", {"type": "hiring_my_interviews", "configuration": {}})
    rows = r.get("data", []) if isinstance(r, dict) else (r if isinstance(r, list) else [])
    out = []
    for i, d in enumerate(x for x in rows if isinstance(x, dict)):
        ev = _pick(d, "evaluationStatus", "evaluation")
        out.append({"id": _pick(d, "interviewId", "id") or str(i), "title": _pick(d, "interviewType", "type", "name"),
                    "status": _pick(d, "status"), "start_at": _pick(d, "start", "date", "time") or None, "end_at": _pick(d, "end") or None,
                    "job_opening_id": _pick(d, "jobOpeningId"), "job_title": _pick(d, "jobOpening", "job"),
                    "candidate_name": _pick(d, "candidate"), "candidate_email": "",
                    "has_evaluation": ev.lower() == "submitted", "meeting_url": _pick(d, "meeting", "conferenc", "link")})
    return out


STAGE = {"new": "新建", "screening": "筛选", "interview": "面试", "offer": "Offer", "hired": "已录用"}


STATUS = {"in_progress": "进行中", "rejected": "已淘汰", "withdrawn": "已撤回", "pending_rejection": "待淘汰",
          "pending_hire": "待录用", "hired": "已录用"}


def _stage_names(ops: list[dict], ids: set[int]) -> dict[int, str]:
    """阶段编号 → 阶段名。Bob 只给编号；同一流程模板的阶段编号是连续递增的，按模板里的阶段顺序对上。"""
    names: dict[int, str] = {}
    stages = next((o.get("pipelineTemplateData", {}).get("stages") for o in ops if o.get("pipelineTemplateData")), None)
    if stages and ids:
        lo = min(ids)
        if max(ids) - lo < len(stages):
            names = {i: stages[i - lo] for i in ids}
    return names


def pipeline() -> list[dict]:
    """我能看到的在招岗位 + 应聘人（含已淘汰 / 撤回），带 Bob 里的具体阶段"""
    g = call("reports_getReportData", {"type": "hiring_job_opening_grid", "configuration": {}})
    ops = [r["jobOpening"] for r in (g.get("data", []) if isinstance(g, dict) else []) if r.get("jobOpening")]
    ops = [o for o in ops if o.get("status") == "open"]
    if not ops:
        return []
    ids = [o["jobOpeningId"] for o in ops]
    apps = call("applications_getApplicationsForJobOpenings", {"jobOpeningIds": ids, "limit": 1000}).get("data", [])
    grid = call("candidates_basicSearchCandidates", {"query": "", "jobOpeningIds": ids, "limit": 1000}).get("data", [])
    stage_of = {r["/application/id"]["value"]: r.get("/application/stageId", {}).get("value") for r in grid}
    names = _stage_names(ops, {v for v in stage_of.values() if v})
    out = []
    for o in ops:
        oid = o["jobOpeningId"]
        rows = []
        for x in (x for x in apps if x.get("jobOpeningId") == oid):
            fn, ln = x.get("firstName") or "", x.get("lastName") or ""
            name = f"{ln}{fn}" if not fn.isascii() else f"{fn} {ln}".strip()
            stage = names.get(stage_of.get(x["applicationId"])) or STAGE.get(x.get("stageType", ""), x.get("stageType", ""))
            rows.append({"id": str(x["applicationId"]), "name": name, "stage": stage,
                         "status": x.get("status", ""), "status_label": STATUS.get(x.get("status", ""), x.get("status", "")),
                         "source": x.get("sourcedByName") or x.get("sourceType") or "", "applied": x.get("dateApplied") or "",
                         "url": f"https://app.hibob.com/hiring/ats/job/{oid}/application/{x['applicationId']}"})
        rows.sort(key=lambda r: (r["status"] != "in_progress", r["applied"]), reverse=False)
        out.append({"id": str(oid), "title": o.get("title", ""), "department": o.get("department") or "", "applicants": rows})
    return out


def call(tool: str, args: dict | None = None) -> object:
    """调用一个 Bob MCP 工具，返回解析后的结果（文本内容能解析成 JSON 就解析）。"""
    headers = {"Authorization": f"Bearer {_access()}", "Accept": "application/json, text/event-stream"}
    with httpx.Client(timeout=60) as cl:
        _, r = _rpc(cl, headers, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                                "clientInfo": {"name": "resume-screener", "version": "1"}}, 1)
        if sid := r.headers.get("mcp-session-id"):
            headers["Mcp-Session-Id"] = sid
        _rpc(cl, headers, "notifications/initialized", None, None)
        if tool == "__list__":
            res, _ = _rpc(cl, headers, "tools/list", {}, 2)
            return [t["name"] for t in (res or {}).get("tools", [])]
        res, _ = _rpc(cl, headers, "tools/call", {"name": tool, "arguments": args or {}}, 2)
    res = res or {}
    if res.get("structuredContent") is not None:
        return res["structuredContent"]
    texts = [c.get("text", "") for c in res.get("content", []) if c.get("type") == "text"]
    joined = "\n".join(texts)
    if res.get("isError"):
        raise MCPError(f"Bob 工具 {tool} 出错：{joined[:200]}")
    try:
        return json.loads(joined)
    except ValueError:
        return joined
