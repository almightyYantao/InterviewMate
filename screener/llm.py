"""Claude 调用封装：structured outputs + 流式，校验失败带错误信息重试 1 次。"""
from __future__ import annotations

import base64
import os
import time
from pathlib import Path
from typing import TypeVar

import anthropic
from pydantic import BaseModel, ValidationError

from . import config

T = TypeVar("T", bound=BaseModel)

SONNET = os.getenv("SCREENER_MODEL_FAST", "claude-sonnet-5-5")
OPUS = os.getenv("SCREENER_MODEL_STRONG", "claude-opus-5-5")
PROMPT_DIR = Path(__file__).parent / "prompts"
PROMPT_VERSION = "v0.1"

_client: anthropic.Anthropic | None = None


def settings() -> dict:
    return config.get()


def reset_client() -> None:
    global _client
    _client = None


def resolve_model(model: str) -> str:
    """设置页里填了模型时覆盖默认的快 / 强两档。"""
    s = settings()
    if model == SONNET and s.get("model_fast"):
        return s["model_fast"]
    if model == OPUS and s.get("model_strong"):
        return s["model_strong"]
    return model


def client() -> anthropic.Anthropic:
    """设置页没填 API Key 时，沿用环境变量 / ant 默认配置。"""
    global _client
    if _client is None:
        s = settings()
        kw = {}
        if s.get("api_key"):
            kw["api_key"] = s["api_key"]
        if s.get("base_url"):
            # SDK 会自己拼 /v1/messages，用户填了 .../v1 时去掉
            kw["base_url"] = s["base_url"].rstrip("/").removesuffix("/v1")
        _client = anthropic.Anthropic(max_retries=3, timeout=900, **kw)
    return _client


def prompt(name: str, **kw) -> str:
    text = (PROMPT_DIR / f"{name}.md").read_text(encoding="utf-8")
    for k, v in kw.items():
        text = text.replace("{" + k + "}", str(v))
    return text


class LLMError(RuntimeError):
    pass


def call_structured(
    *,
    stage: str,
    model: str,
    system: str,
    user: str,
    schema: type[T],
    effort: str = "medium",
    pdf: bytes | None = None,
    meta: list[dict] | None = None,
    max_tokens: int = 64000,
    json_mode: bool = False,
) -> T:
    """system 部分加 cache_control，同一岗位多份简历时可复用缓存。"""
    content: list[dict] = []
    if pdf:
        content.append({"type": "document", "source": {
            "type": "base64", "media_type": "application/pdf",
            "data": base64.standard_b64encode(pdf).decode()}})
    content.append({"type": "text", "text": user})
    messages: list[dict] = [{"role": "user", "content": content}]

    model = resolve_model(model)
    if json_mode:
        # 题目这种长而深的嵌套结构，用结构化输出约束时模型常交出空壳（字段全空）；改为普通 JSON 再用 pydantic 校验
        import json as _json
        system += ("\n\n只输出一个 JSON 对象，符合下面的 JSON Schema，不要任何其他文字、不要代码块：\n"
                   + _json.dumps(schema.model_json_schema(by_alias=True), ensure_ascii=False))
    if settings().get("ai_language") == "en":
        system += ("\n\nOutput language: write every free-text field in English (translate any Chinese "
                   "examples above). Keep enum / Literal values, IDs and quotes from the resume exactly as given.")
    last_err = ""
    for attempt in range(2):
        t0 = time.time()
        with client().messages.stream(
            model=model,
            max_tokens=max_tokens,
            system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
            messages=messages,
            **({} if json_mode else {"output_format": schema}),
            output_config={"effort": effort},
        ) as stream:
            msg = stream.get_final_message()
        if meta is not None:
            u = msg.usage
            meta.append({
                "stage": stage, "model": model, "prompt_version": PROMPT_VERSION, "attempt": attempt + 1,
                "input_tokens": u.input_tokens, "output_tokens": u.output_tokens,
                "cache_read": getattr(u, "cache_read_input_tokens", 0) or 0,
                "cache_write": getattr(u, "cache_creation_input_tokens", 0) or 0,
                "seconds": round(time.time() - t0, 1), "stop_reason": msg.stop_reason,
            })
        if msg.stop_reason == "refusal":
            raise LLMError(f"[{stage}] 模型拒绝：{getattr(msg, 'stop_details', None)}")
        if msg.stop_reason == "max_tokens":
            last_err = "输出被截断（max_tokens）"
        else:
            try:
                parsed = None if json_mode else msg.parsed_output
                if parsed is not None:
                    return parsed
                text = "".join(b.text for b in msg.content if b.type == "text")
                if json_mode:
                    text = text[text.find("{"):text.rfind("}") + 1]
                return schema.model_validate_json(text)
            except ValidationError as e:
                last_err = str(e)[:2000]
        messages = [
            {"role": "user", "content": content + [{"type": "text", "text":
             f"上一次输出未通过校验：{last_err}\n请修正后重新输出完整结果。"}]},
        ]
    raise LLMError(f"[{stage}] 结构化输出两次均失败：{last_err}")
