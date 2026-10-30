"""把面试评价以卡片形式发到 Lark 群（群自定义机器人 Webhook）。"""
from __future__ import annotations

import base64
import hashlib
import hmac
import time

import httpx

from . import config

COLOR = {"通过": "green", "待定": "orange", "不通过": "red"}
LABEL = {"excellent": "优秀", "pass": "合格", "fail": "不合格", "skip": "跳过"}


class LarkError(RuntimeError):
    pass


def card(d: dict) -> dict:
    """d: candidate, position, round, decision, comment, score, highlights, concerns, counts, note"""
    md = []
    head = f"**结论：{d['decision'] or '未出结论'}**　｜　简历匹配分 {d['score']:.1f} / 10"
    if d["round"] > 1:
        head += f"　｜　第 {d['round']} 轮"
    md.append(head)
    if d["comment"]:
        md.append(d["comment"])
    cnt = "　".join(f"{LABEL[k]} {v}" for k, v in d["counts"].items() if v)
    if cnt:
        md.append(f"**逐题打分**：{cnt}")
    if d["highlights"]:
        md.append("**亮点**\n" + "\n".join(f"- {x}" for x in d["highlights"]))
    if d["concerns"]:
        md.append("**不足**\n" + "\n".join(f"- {x}" for x in d["concerns"]))
    if d["note"]:
        md.append(f"**面试官整体反馈**\n{d['note']}")
    return {"msg_type": "interactive", "card": {
        "config": {"wide_screen_mode": True},
        "header": {"template": COLOR.get(d["decision"], "blue"),
                   "title": {"tag": "plain_text", "content": f"面试评价 · {d['candidate']} · {d['position']}"}},
        "elements": [{"tag": "markdown", "content": x} for x in md] + [
            {"tag": "note", "elements": [{"tag": "plain_text", "content": "由「面搭子」生成，AI 评价需面试官复核"}]}],
    }}


def send(payload: dict) -> None:
    c = config.get()
    url = c["lark_webhook"]
    if not url:
        raise LarkError("还没有填 Lark 群机器人的 Webhook 地址（设置 › 通用）")
    if c["lark_secret"]:
        ts = str(int(time.time()))
        sign = base64.b64encode(hmac.new(f"{ts}\n{c['lark_secret']}".encode(), digestmod=hashlib.sha256).digest()).decode()
        payload = {**payload, "timestamp": ts, "sign": sign}
    try:
        r = httpx.post(url, json=payload, timeout=15)
    except httpx.HTTPError as e:
        raise LarkError(f"连不上 Lark：{e}")
    d = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
    if r.status_code >= 400 or d.get("code", 0) != 0:
        raise LarkError(f"Lark 拒绝了这条消息：{d.get('msg') or r.text[:200]}（检查 Webhook 地址、签名密钥、关键词设置）")
