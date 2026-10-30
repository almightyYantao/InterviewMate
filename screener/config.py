"""用户设置：保存在 data/settings.json，界面「设置」里改。没填的项用这里的默认值。"""
from __future__ import annotations

import copy
import json
import os
from pathlib import Path

PATH = Path(os.getenv("SCREENER_DATA", Path(__file__).resolve().parent.parent / "data")) / "settings.json"

DEFAULTS: dict = {
    # AI 接口
    "api_key": "",
    "base_url": "",
    "model_fast": "",
    "model_strong": "",
    # HiBob（Bob Hiring，只读）
    "hibob_user_id": "",
    "hibob_token": "",
    "hibob_sandbox": False,
    "hibob_oauth": {},          # 个人 Bob 账号登录（官方 MCP）的令牌
    "hibob_email": "",          # 我自己的 HiBob 邮箱：只看我当面试官的面试
    "hibob_employee_id": "",    # 由邮箱换算得到，也可以手填
    # 语言：zh / en
    "ai_language": "zh",
    # 语音转写：识别语言、停顿多少秒算一句
    "speech_locale": "zh-CN",
    "silence_seconds": 1.5,
    "capture_app": "",          # 候选人声音来自哪个 App（Bundle ID），空 = 自动找会议软件
    # 日历：Google 日历「iCal 格式的私密地址」；面试前多少分钟提醒
    "calendar_ics_url": "",
    # Lark 群自定义机器人：把面试评价发到群里
    "lark_webhook": "",
    "lark_secret": "",
    "remind_minutes": 15,
    # 岗位默认值
    "company_ctx": "",
    "interview_minutes": 60,
    "weights": {"must": 3, "plus": 1, "duty": 2, "emphasis": 2},
    # 打分规则
    "scoring": {"match": 1.0, "partial": 0.5, "missing": 0.0, "unknown": 0.3,
                "veto_weight": 5, "advance": 7.5, "reject": 5.0, "max_high_doubts": 1},
    # 数据保留
    "retention_days": int(os.getenv("SCREENER_RETENTION_DAYS", "180")),
}


def _merge(base: dict, over: dict) -> dict:
    out = copy.deepcopy(base)
    for k, v in over.items():
        if isinstance(v, dict) and v and isinstance(out.get(k), dict) and out[k]:
            out[k] = _merge(out[k], v)
        elif k in out:
            out[k] = v   # 默认是空字典的项（如登录令牌）整体替换
    return out


def get() -> dict:
    try:
        raw = json.loads(PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raw = {}
    return _merge(DEFAULTS, raw)


def save(d: dict) -> dict:
    merged = _merge(get(), d)
    PATH.parent.mkdir(parents=True, exist_ok=True)
    PATH.write_text(json.dumps(merged, ensure_ascii=False, indent=1), encoding="utf-8")
    PATH.chmod(0o600)
    return merged
