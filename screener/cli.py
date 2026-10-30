"""命令行：python -m screener.cli --jd JD文件 --resume 简历文件 [-o 输出目录]"""
from __future__ import annotations

import argparse
import sys
from datetime import date
from pathlib import Path

from . import config, parsing, pipeline, render
from .schemas import Report


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="简历筛选与一面准备材料生成")
    ap.add_argument("--jd", required=True, help="JD 文件（md / txt / docx / pdf）")
    ap.add_argument("--resume", required=True, help="简历文件（pdf / docx / md / txt）")
    ap.add_argument("-o", "--out", default="out", help="输出目录")
    ap.add_argument("--minutes", type=int, default=60, help="面试时长（分钟）")
    ap.add_argument("--context", help="公司环境描述（文本或文件路径），默认使用内置描述")
    ap.add_argument("--today", help="以哪天为“今天”计算年限，YYYY-MM-DD")
    ap.add_argument("--no-mask", action="store_true", help="不对手机号 / 邮箱 / 身份证脱敏")
    ap.add_argument("--from-json", help="跳过 LLM，用已有 report.json 重新渲染")
    a = ap.parse_args(argv)

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    resume_doc = parsing.load(a.resume, mask=not a.no_mask)

    if a.from_json:
        report = Report.model_validate_json(Path(a.from_json).read_text())
    else:
        jd_doc = parsing.load(a.jd, mask=False)
        ctx = config.get()["company_ctx"]
        if a.context:
            p = Path(a.context)
            ctx = p.read_text(encoding="utf-8") if p.exists() else a.context
        today = date.fromisoformat(a.today) if a.today else date.today()
        report = pipeline.run(jd_doc, resume_doc, company_ctx=ctx, minutes=a.minutes, today=today,
                              progress=lambda s: print(f"→ {s}", file=sys.stderr, flush=True))
        (out / "report.json").write_text(report.model_dump_json(indent=1, by_alias=True), encoding="utf-8")

    stem = f"{report.candidate}-{report.position}".replace("/", "_")
    md = render.markdown(report, resume_doc.pii)
    (out / f"{stem}-一面准备.md").write_text(md, encoding="utf-8")
    (out / f"{stem}-一面准备.docx").write_bytes(render.docx_bytes(md))
    (out / f"{stem}-面试记录表.md").write_text(render.markdown(report, resume_doc.pii, with_answers=False), encoding="utf-8")

    tin = sum(m.get("input_tokens", 0) + m.get("cache_read", 0) + m.get("cache_write", 0) for m in report.model_meta)
    tout = sum(m.get("output_tokens", 0) for m in report.model_meta)
    print(f"\n结论：{report.conclusion.decision}  匹配分 {report.conclusion.score}/10  "
          f"题目 {len(report.questions)} 道 / {sum(q.minutes for q in report.questions)} 分钟")
    print(f"tokens：输入 {tin}，输出 {tout}；校验日志 {len(report.validation)} 条")
    print(f"输出目录：{out.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
