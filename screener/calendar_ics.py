"""读取 Google 日历「iCal 格式的私密地址」，把日程和 App 里的候选人对上。只读。"""
from __future__ import annotations

import re
import time
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import httpx

from . import config

_cache: dict = {"url": "", "at": 0.0, "text": ""}


class CalendarError(RuntimeError):
    pass


def _fetch(url: str) -> str:
    if _cache["url"] == url and time.time() - _cache["at"] < 120:
        return _cache["text"]
    try:
        r = httpx.get(url, timeout=30, follow_redirects=True)
    except httpx.HTTPError as e:
        raise CalendarError(f"连不上日历地址：{e}")
    if r.status_code != 200 or "BEGIN:VCALENDAR" not in r.text:
        raise CalendarError(f"日历地址无效（{r.status_code}）：请在 Google 日历设置里复制「iCal 格式的私密地址」")
    _cache.update(url=url, at=time.time(), text=r.text)
    return r.text


def _unescape(s: str) -> str:
    return s.replace("\\n", "\n").replace("\\N", "\n").replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\")


def _dt(params: str, value: str) -> datetime | None:
    try:
        if "VALUE=DATE" in params or len(value) == 8:
            d = date(int(value[:4]), int(value[4:6]), int(value[6:8]))
            return datetime(d.year, d.month, d.day, tzinfo=datetime.now().astimezone().tzinfo)
        dt = datetime.strptime(value.rstrip("Z"), "%Y%m%dT%H%M%S")
        if value.endswith("Z"):
            return dt.replace(tzinfo=timezone.utc)
        m = re.search(r"TZID=([^;:]+)", params)
        return dt.replace(tzinfo=ZoneInfo(m.group(1)) if m else datetime.now().astimezone().tzinfo)
    except (ValueError, KeyError):
        return None


def parse(text: str) -> list[dict]:
    lines: list[str] = []
    for raw in text.splitlines():
        if raw.startswith((" ", "\t")) and lines:
            lines[-1] += raw[1:]
        else:
            lines.append(raw)
    events, cur = [], None
    for l in lines:
        if l == "BEGIN:VEVENT":
            cur = {"attendees": []}
        elif l == "END:VEVENT" and cur is not None:
            if cur.get("start") and cur.get("status") != "CANCELLED":
                events.append(cur)
            cur = None
        elif cur is not None and ":" in l:
            head, val = l.split(":", 1)
            name, _, params = head.partition(";")
            if name == "UID":
                cur["uid"] = val
            elif name == "SUMMARY":
                cur["title"] = _unescape(val)
            elif name == "DESCRIPTION":
                cur["description"] = _unescape(val)
            elif name == "LOCATION":
                cur["location"] = _unescape(val)
            elif name == "STATUS":
                cur["status"] = val
            elif name == "DTSTART":
                cur["start"] = _dt(params, val)
            elif name == "DTEND":
                cur["end"] = _dt(params, val)
            elif name == "ATTENDEE":
                m = re.search(r'CN="?([^";:]+)', params)
                cur["attendees"].append((m.group(1) if m else "") + " " + val.replace("mailto:", ""))
    return events


MEETINGS = [  # (名称, 链接里的域名关键字)，排前面的优先；Google Meet 常是日历自动加的，放最后
    ("腾讯会议", r"meeting\.tencent\.com|voovmeeting\.com|wemeet"),
    ("飞书会议", r"vc\.feishu\.cn|meetings\.feishu\.cn|feishu\.cn/(?:vc|meeting)"),
    ("Lark 会议", r"vc\.larksuite\.com|larksuite\.com/(?:vc|meeting)|vc\.larkoffice"),
    ("Zoom", r"zoom\.us|zoom\.com\.cn"),
    ("Teams", r"teams\.microsoft\.com|teams\.live\.com"),
    ("钉钉会议", r"dingtalk\.com"),
    ("Webex", r"webex\.com"),
    ("Google Meet", r"meet\.google\.com"),
]


def meetings(text: str) -> list[dict]:
    """从地点、说明里找出所有会议：[{app, url, code}]，按 MEETINGS 的顺序；只有会议号没有链接时 url 为空"""
    text = text or ""
    found: list[dict] = []
    urls = re.findall(r"https?://[^\s<>\"'）)\]，。]+", text)
    for name, pat in MEETINGS:
        u = next((u for u in urls if re.search(pat, u, re.I)), "")
        code = ""
        brand = {"腾讯会议": r"腾讯会议|VooV|wemeet", "飞书会议": r"飞书", "Lark 会议": r"Lark",
                 "Zoom": r"Zoom", "钉钉会议": r"钉钉"}.get(name)
        if brand:
            # 有这个软件的链接时，通用的「会议号 / Meeting ID」也算；没链接时必须写了软件名
            kw = brand + (r"|会议号|会议 ?ID|Meeting ID" if u else "")
            if u or re.search(brand, text, re.I):
                m = re.search(rf"(?:{kw})[^\d\n]{{0,20}}(\d[\d \-]{{6,14}}\d)", text, re.I)
                code = re.sub(r"[ \-]", "", m.group(1)) if m else ""
        if u or code:
            found.append({"app": name, "url": u, "code": code})
    return found


def match(events: list[dict], candidates: list[dict]) -> list[dict]:
    """App 读到的本机日历日程 {uid,title,start,end,notes,location,attendees} → 对上候选人"""
    out = []
    for e in events:
        hay = re.sub(r"\s", "", " ".join([e.get("title", ""), e.get("notes", ""), " ".join(e.get("attendees", []))])).lower()
        hit = next((c for c in candidates if len(c["key"]) >= 2 and c["key"] in hay), None)
        ms = meetings(e.get("location", "") + "\n" + e.get("notes", "") + "\n" + e.get("url", ""))
        mt = ms[0] if ms else {"app": "", "url": "", "code": ""}
        out.append({"uid": e.get("uid", ""), "title": e.get("title", ""), "start": e["start"], "end": e.get("end") or e["start"],
                    "meeting_url": mt["url"], "meeting_app": mt["app"], "meeting_code": mt["code"], "meetings": ms,
                    "candidate_id": hit["id"] if hit else None, "candidate_name": hit["name"] if hit else None,
                    "position_id": hit["position_id"] if hit else None})
    out.sort(key=lambda x: x["start"])
    return out


def upcoming(candidates: list[dict], days_back: int = 1, days_ahead: int = 14) -> list[dict]:
    """未来两周（含昨天）的日程；标题、描述、参会人里出现候选人姓名的就绑定上"""
    url = config.get()["calendar_ics_url"]
    if not url:
        return []
    now = datetime.now(timezone.utc)
    lo, hi = now - timedelta(days=days_back), now + timedelta(days=days_ahead)
    out = []
    for e in parse(_fetch(url)):
        st = e["start"]
        if not (lo <= st <= hi):
            continue
        hay = re.sub(r"\s", "", " ".join([e.get("title", ""), e.get("description", ""), " ".join(e["attendees"])])).lower()
        hit = next((c for c in candidates if c["name"] and len(c["key"]) >= 2 and c["key"] in hay), None)
        ms = meetings(e.get("location", "") + "\n" + e.get("description", ""))
        mt = ms[0] if ms else {"app": "", "url": "", "code": ""}
        out.append({"uid": e.get("uid", ""), "title": e.get("title", ""), "start": st.isoformat(),
                    "end": (e.get("end") or st + timedelta(hours=1)).isoformat(),
                    "meeting_url": mt["url"], "meeting_app": mt["app"], "meeting_code": mt["code"], "meetings": ms,
                    "candidate_id": hit["id"] if hit else None, "candidate_name": hit["name"] if hit else None,
                    "position_id": hit["position_id"] if hit else None})
    out.sort(key=lambda x: x["start"])
    return out


def meeting(text: str) -> dict:
    """首选的那个会议"""
    m = meetings(text)
    return m[0] if m else {"app": "", "url": "", "code": ""}
