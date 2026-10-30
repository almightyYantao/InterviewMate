"""导出为单文件 HTML：样式内联，浏览器打开即可看，也能直接打印成 PDF。"""
from __future__ import annotations

from html import escape as e

from .parsing import unmask
from .render import LEVEL, _sections, _source
from .schemas import DECISION_LABEL, Report

DEC_COLOR = {"advance": "#16a34a", "conditional": "#ea8a0c", "reject": "#e5484d"}
SEV = {"high": ("高", "#e5484d"), "medium": ("中", "#ea8a0c"), "low": ("低", "#8b8d98")}
VERDICT = {"match": ("具备", "#16a34a"), "partial": ("部分", "#ea8a0c"), "missing": ("缺失", "#e5484d"),
           "unknown": ("无法判断", "#8b8d98")}
SEC_COLOR = {"背景核实": "#a855f7", "项目深挖": "#3869fa", "核心能力": "#0d9488", "缺口场景": "#ea8a0c", "软性要求": "#db2777"}

CSS = """
:root{--brand:#3869fa;--page:#f4f6fb;--text:#1c2024;--muted:#60646c;--line:#e6e8ee}
*{box-sizing:border-box}body{margin:0;background:var(--page);color:var(--text);
font:15px/1.65 -apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue","Microsoft YaHei",sans-serif}
.wrap{max-width:960px;margin:0 auto;padding:40px 28px 80px}
.hero{background:#fff;border-radius:20px;padding:28px 32px;display:flex;gap:28px;align-items:center;box-shadow:0 1px 2px rgba(0,0,0,.04)}
.ring{--v:0;--c:var(--brand);width:112px;height:112px;border-radius:50%;flex:none;display:grid;place-items:center;
background:conic-gradient(var(--c) calc(var(--v)*1%),#eceef3 0)}
.ring b{width:90px;height:90px;border-radius:50%;background:#fff;display:grid;place-items:center;font-size:30px}
h1{margin:0;font-size:28px}.sub{color:var(--muted);margin-top:2px}
.badge{display:inline-block;padding:2px 10px;border-radius:999px;font-size:12.5px;font-weight:600;vertical-align:middle}
.note{font-size:12.5px;color:var(--muted);margin:14px 4px 28px}
h2{font-size:20px;margin:34px 0 14px;display:flex;align-items:center;gap:10px}
h2 .n{font-size:12px;color:var(--muted);background:#fff;border-radius:999px;padding:1px 9px;font-weight:600}
h3{font-size:15px;color:var(--muted);margin:22px 0 10px}
.card{background:#fff;border-radius:16px;padding:18px 22px;margin-bottom:12px;box-shadow:0 1px 2px rgba(0,0,0,.04)}
.row{display:flex;gap:12px;align-items:flex-start}.grow{flex:1;min-width:0}
.ev{font-size:13px;color:var(--muted);margin-top:6px}.ev span{color:var(--brand);font-family:ui-monospace,Menlo,monospace;margin-right:6px}
.ask{margin-top:8px;font-size:13.5px;color:#11181c;background:var(--page);border-radius:10px;padding:8px 12px}
table{width:100%;border-collapse:collapse;background:#fff;border-radius:16px;overflow:hidden;box-shadow:0 1px 2px rgba(0,0,0,.04)}
th{font-size:12px;text-align:left;color:var(--muted);font-weight:600;padding:12px 16px;background:#fafbfd}
td{padding:12px 16px;border-top:1px solid var(--line);vertical-align:top;font-size:14px}
td .id{font-family:ui-monospace,Menlo,monospace;color:var(--brand);font-size:12px;margin-right:6px}
.q{border-left:4px solid var(--c);}
.qh{display:flex;gap:12px;align-items:flex-start}.qid{flex:none;font-weight:700;color:var(--c);background:color-mix(in srgb,var(--c) 12%,#fff);
border-radius:8px;width:34px;height:28px;display:grid;place-items:center;font-size:13px}
.qt{font-weight:600;font-size:15.5px}.meta{font-size:12.5px;color:var(--muted);margin-top:4px}
.src{font-size:13px;color:var(--muted);margin:10px 0 0 46px}
.blk{margin:12px 0 0 46px;border-radius:12px;padding:10px 14px}
.blk b{display:block;font-size:12px;margin-bottom:4px}
.blk ol,.blk ul{margin:0;padding-left:20px}.blk li{margin:2px 0}
.ans{background:#eef3ff}.ans b{color:var(--brand)}.key{font-weight:600}.key::after{content:" ★";color:#f59e0b}
.fu{background:#ecfdf8}.fu b{color:#0d9488}.rf{background:#fff1f1}.rf b{color:#e5484d}
.rub{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin:12px 0 0 46px}
.rub div{border:1.5px solid var(--c);border-radius:10px;padding:8px 12px;font-size:13px;color:var(--muted)}
.rub div b{display:block;color:var(--c);font-size:12px}
.score{margin:12px 0 0 46px;font-size:14px}.lines{margin:8px 0 0 46px;height:72px;
background:repeating-linear-gradient(transparent 0 23px,var(--line) 23px 24px)}
.signals{display:grid;grid-template-columns:1fr 1fr;gap:12px}.signals ul{margin:6px 0 0;padding-left:18px}
.chips span{display:inline-block;background:var(--page);border-radius:999px;padding:2px 10px;margin:4px 6px 0 0;font-size:13px}
@media print{body{background:#fff}.wrap{padding:0}.card,.hero,table{box-shadow:none;border:1px solid var(--line)}
.q,.card{break-inside:avoid}}
"""


def _badge(text: str, color: str) -> str:
    return f'<span class="badge" style="color:{color};background:{color}1a">{e(text)}</span>'


def html(r: Report, pii: dict[str, str] | None = None, with_answers: bool = True) -> str:
    c = r.conclusion
    reqs = {x.id: x for x in r.jd.requirements}
    total = sum(q.minutes for q in r.questions)
    title = "简历筛选与一面准备" if with_answers else "一面面试记录表"
    col = DEC_COLOR.get(c.decision, "#8b8d98")
    o: list[str] = [f"<!doctype html><html lang='zh'><head><meta charset='utf-8'>"
                    f"<meta name='viewport' content='width=device-width,initial-scale=1'>"
                    f"<title>{e(r.candidate)} · {e(r.position)} · {title}</title><style>{CSS}</style></head><body><div class='wrap'>"]

    # 顶部
    o.append("<div class='hero'>")
    if with_answers:
        o.append(f"<div class='ring' style='--v:{c.score * 10:.0f};--c:{col}'><b>{c.score:.1f}</b></div>")
    o.append(f"<div class='grow'><h1>{e(r.candidate)} "
             + (_badge(DECISION_LABEL[c.decision], col) if with_answers else "") +
             f"</h1><div class='sub'>{e(r.position)} · {title} · 面试 {total} 分钟</div>")
    if with_answers:
        o.append(f"<p style='margin:10px 0 0'>{e(c.summary)}</p>")
        if c.veto:
            o.append("<p style='margin:8px 0 0;color:#e5484d;font-size:13.5px'>一票否决（结论上限为「有条件推进」）：" +
                     "；".join(e(f"{v} {reqs[v].text if v in reqs else ''}") for v in c.veto) + "</p>")
        if c.must_verify:
            o.append("<div class='chips' style='margin-top:6px'><b style='font-size:12.5px;color:#60646c'>必须核实</b> " +
                     "".join(f"<span>{e(x)}</span>" for x in c.must_verify) + "</div>")
    o.append("</div></div>")
    o.append("<div class='note'>AI 生成，需人工复核。是否推进由面试官决定；出生日期仅用于时间线校验，年龄、性别、婚育、籍贯不参与评分和出题。</div>")

    if with_answers:
        order = {"high": 0, "medium": 1, "low": 2}
        o.append(f"<h2>简历疑点 <span class='n'>{len(r.doubts)}</span></h2>")
        for d in sorted(r.doubts, key=lambda d: order[d.severity]):
            t, sc = SEV[d.severity]
            ev = "".join(f"<div><span>L{x.line}</span>「{e(x.quote)}」</div>" for x in d.evidence)
            o.append(f"<div class='card' style='border-left:4px solid {sc}'><div class='row'>{_badge(t, sc)}"
                     f"<div class='grow'><b>{e(d.title)}</b><div class='ev'>{ev}</div>"
                     + (f"<div class='ask'>核实：{e(d.verify_question)}</div>" if not d.verify_question.startswith("（") else "")
                     + "</div></div></div>")

        o.append(f"<h2>JD 匹配度 <span class='n'>{len(r.match)}</span></h2><table><tr><th>JD 要求</th><th>级别 / 权重</th><th>匹配</th><th>说明与证据</th></tr>")
        for m in r.match:
            req = reqs.get(m.req_id)
            t, vc = VERDICT[m.verdict]
            text = e(req.text) if req else ""
            if req and req.emphasized:
                text = f"<b>{text}</b>"
            ev = "".join(f"<div><span>L{x.line}</span>「{e(x.quote)}」</div>" for x in m.evidence)
            lvl = f"{LEVEL[req.level]} · {req.weight}" if req else ""
            o.append(f"<tr><td><span class='id'>{m.req_id}</span>{text}</td><td style='white-space:nowrap;color:#60646c'>{lvl}</td>"
                     f"<td>{_badge(t, vc)}</td><td>{e(m.reason)}<div class='ev'>{ev}</div></td></tr>")
        o.append("</table>")

    o.append(f"<h2>{'面试题与参考答案' if with_answers else '面试题'} <span class='n'>{len(r.questions)} 题 · {total} 分钟</span></h2>")
    for sec, qs in _sections(r).items():
        sc = SEC_COLOR.get(sec, "#3869fa")
        o.append(f"<h3>{e(sec)} · {sum(q.minutes for q in qs)} 分钟</h3>")
        for q in qs:
            o.append(f"<div class='card q' style='--c:{sc}'><div class='qh'><div class='qid'>{e(q.id.lstrip('Q'))}</div>"
                     f"<div class='grow'><div class='qt'>{e(q.question)}</div><div class='meta'>{q.minutes} 分钟</div></div></div>"
                     f"<div class='src'>来源：{e(_source(q, r))}</div>")
            if with_answers:
                key = set(q.key_points)
                pts = "".join(f"<li class='{'key' if p in key else ''}'>{e(p)}</li>" for p in q.answer_points)
                o.append(f"<div class='blk ans'><b>参考答案要点</b><ol>{pts}</ol></div>")
            if q.follow_ups:
                o.append("<div class='blk fu'><b>追问</b><ul>" + "".join(f"<li>{e(x)}</li>" for x in q.follow_ups) + "</ul></div>")
            if with_answers:
                if q.red_flags:
                    o.append("<div class='blk rf'><b>红旗信号</b><ul>" + "".join(f"<li>{e(x)}</li>" for x in q.red_flags) + "</ul></div>")
                o.append(f"<div class='rub'><div style='--c:#16a34a'><b>优秀</b>{e(q.rubric.excellent)}</div>"
                         f"<div style='--c:#3869fa'><b>合格</b>{e(q.rubric.pass_)}</div>"
                         f"<div style='--c:#e5484d'><b>不合格</b>{e(q.rubric.fail)}</div></div>")
            else:
                o.append("<div class='score'>☐ 优秀　☐ 合格　☐ 不合格　☐ 跳过</div><div class='lines'></div>")
            o.append("</div>")

    if with_answers:
        o.append("<h2>评价建议</h2><div class='signals'>"
                 "<div class='card'><b style='color:#16a34a'>通过信号</b><ul>" + "".join(f"<li>{e(x)}</li>" for x in c.pass_signals) + "</ul></div>"
                 "<div class='card'><b style='color:#e5484d'>不通过信号</b><ul>" + "".join(f"<li>{e(x)}</li>" for x in c.fail_signals) + "</ul></div></div>")
    else:
        o.append("<h2>面试结论</h2><div class='card'>☐ 通过　☐ 待定　☐ 不通过<div class='lines' style='margin-left:0;height:120px'></div></div>")
    o.append("</div></body></html>")
    text = "".join(o)
    return unmask(text, pii) if pii else text
