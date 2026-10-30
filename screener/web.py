"""Web 服务：uv run uvicorn screener.web:app --port 8000

MVP 简化：后台线程代替 RQ，SQLite 代替 PostgreSQL，请求头 X-User 代替 Keycloak 登录。
"""
from __future__ import annotations

import json
import re
import threading
from datetime import date
from pathlib import Path

import httpx
from fastapi import FastAPI, File, Form, Header, HTTPException, Request, UploadFile
from fastapi.responses import HTMLResponse, Response
from pydantic import BaseModel

from . import calendar_ics, config, lark, evaluation, hibob, hibob_mcp, llm, render_html, snippet, parsing, pipeline, render, store
from .schemas import JDStruct, Report

app = FastAPI(title="简历筛选与面试题生成")
_lock = threading.Lock()


def conn():
    return store.db()


@app.on_event("startup")
def _startup():
    with _lock:
        store.purge_expired(conn())
    # 后台重启（App 重开、闪退）时，正在生成的任务线程已经没了：把没跑完的重新排队
    c = conn()
    for r in c.execute("SELECT id FROM candidates WHERE status NOT IN ('done','failed')").fetchall():
        c.execute("UPDATE candidates SET progress=? WHERE id=?", ("后台重启，重新生成中", r["id"]))
        c.commit()
        threading.Thread(target=_run_candidate, args=(r["id"],), daemon=True).start()


def _user(x_user: str | None) -> str:
    return x_user or "local"


# ---------- 岗位 ----------


class PositionIn(BaseModel):
    title: str
    jd_raw: str
    company_ctx: str | None = None
    interview_minutes: int | None = None


@app.get("/positions")
def list_positions():
    rows = conn().execute("SELECT * FROM positions ORDER BY updated_at DESC").fetchall()
    return [{**dict(r), "jd_struct": json.loads(r["jd_struct"]) if r["jd_struct"] else None} for r in rows]


def _structure_position(pid: str):
    c = conn()
    p = c.execute("SELECT * FROM positions WHERE id=?", (pid,)).fetchone()
    try:
        js = pipeline.structure_jd(parsing.load_text(p["jd_raw"]), [])
        c.execute("UPDATE positions SET jd_struct=? WHERE id=?", (js.model_dump_json(), pid))
        c.commit()
    except Exception as e:  # noqa: BLE001
        c.execute("UPDATE positions SET jd_struct=? WHERE id=?", (json.dumps({"error": str(e)}), pid))
        c.commit()


@app.post("/positions")
def create_position(body: PositionIn, x_user: str | None = Header(None)):
    c = conn()
    pid = store.new_id()
    c.execute("INSERT INTO positions VALUES (?,?,?,?,?,?,?,?)",
              (pid, body.title, body.jd_raw, None,
               body.company_ctx if body.company_ctx is not None else config.get()["company_ctx"],
               body.interview_minutes or config.get()["interview_minutes"], _user(x_user), store.now()))
    c.commit()
    threading.Thread(target=_structure_position, args=(pid,), daemon=True).start()
    return {"id": pid}


class PositionPatch(BaseModel):
    title: str | None = None
    jd_raw: str | None = None
    jd_struct: dict | None = None      # 手动调整权重 / 级别
    company_ctx: str | None = None
    interview_minutes: int | None = None


@app.put("/positions/{pid}")
def update_position(pid: str, body: PositionPatch, x_user: str | None = Header(None)):
    c = conn()
    p = c.execute("SELECT * FROM positions WHERE id=?", (pid,)).fetchone()
    if not p:
        raise HTTPException(404)
    jd_changed = body.jd_raw is not None and body.jd_raw != p["jd_raw"]
    fields = body.model_dump(exclude_none=True)
    if "jd_struct" in fields:
        fields["jd_struct"] = JDStruct.model_validate(fields["jd_struct"]).model_dump_json()
    if jd_changed:
        fields["jd_struct"] = None
    for k, v in fields.items():
        c.execute(f"UPDATE positions SET {k}=? WHERE id=?", (v, pid))
    c.execute("UPDATE positions SET updated_at=? WHERE id=?", (store.now(), pid))
    c.commit()
    store.audit(c, _user(x_user), "edit_position", pid)
    if jd_changed:
        threading.Thread(target=_structure_position, args=(pid,), daemon=True).start()
    return {"ok": True, "restructuring": jd_changed}


# ---------- 候选人 ----------


def _progress(cid: str):
    def f(msg: str):
        c = conn()
        c.execute("UPDATE candidates SET progress=? WHERE id=?", (msg, cid))
        c.commit()
    return f


def _previous_rounds(c, cid: str) -> tuple[str, list[str]]:
    """前几轮的结论和遗留：仍存疑 / 没问到的疑点、答得不好或没问到的题、不足、整体反馈"""
    rep = store.latest_report(c, cid)
    b = json.loads(rep["body"])
    qs = {q["id"]: q for q in b["questions"]}
    ev = c.execute("SELECT decision, comment FROM evaluations WHERE candidate_id=? ORDER BY created_at DESC LIMIT 1", (cid,)).fetchone()
    tr = c.execute("SELECT summary FROM transcripts WHERE candidate_id=? AND summary IS NOT NULL ORDER BY created_at DESC LIMIT 1", (cid,)).fetchone()
    sm = json.loads(tr["summary"]) if tr else {}
    carry: list[str] = []
    for d in sm.get("doubts", []):
        if d.get("result") != "已澄清":
            carry.append(f"{d['doubt']}（上一轮{d['result']}：{d.get('note', '')}）")
    for r in sm.get("questions", []):
        q = qs.get(r.get("question_id"), {})
        if r.get("suggested_score") == "fail" or r.get("missed"):
            carry.append(f"{q.get('question', '')[:40]}…：没答到 {'、'.join(r.get('missed', [])[:3])}")
    for s in c.execute("SELECT question_id, score, note FROM interview_scores WHERE report_id=?", (rep["id"],)):
        q = qs.get(s["question_id"], {})
        if s["score"] == "fail":
            carry.append(f"{q.get('question', '')[:40]}…：上一轮不合格{('，' + s['note']) if s['note'] else ''}")
        elif s["score"] == "skip" and not sm:
            carry.append(f"上一轮没问到：{q.get('question', '')[:60]}")
    carry += [f"不足：{x}" for x in sm.get("concerns", [])]
    if not sm:   # 没有转写总结时，用疑点兜底
        carry += [f"{d['title']}（上一轮未核实）" for d in b["doubts"] if d["severity"] == "high"]
    carry = list(dict.fromkeys(x for x in carry if x.strip()))[:12]
    text = (f"第 {b.get('round', 1)} 轮结论：{ev['decision'] if ev else '未出结论'}\n"
            f"评价：{ev['comment'] if ev else ''}\n整体反馈：{store.get_note(c, cid)}\n遗留：\n" + "\n".join(f"- {x}" for x in carry))
    return text, carry


def _run_candidate(cid: str, only_questions: bool = False, next_round: bool = False):
    c = conn()
    cand = c.execute("SELECT * FROM candidates WHERE id=?", (cid,)).fetchone()
    p = c.execute("SELECT * FROM positions WHERE id=?", (cand["position_id"],)).fetchone()
    c.execute("UPDATE candidates SET status='processing', error=NULL WHERE id=?", (cid,))
    c.commit()
    try:
        doc = parsing.load(store.file_dir() / cand["file_key"])
        ctx = p["company_ctx"] or config.get()["company_ctx"]
        if next_round:
            prev = Report.model_validate_json(store.latest_report(c, cid)["body"])
            text, carry = _previous_rounds(c, cid)
            rep = pipeline.regenerate_questions(prev, doc, ctx, progress=_progress(cid), previous=text, carry=carry)
        elif only_questions:
            prev = Report.model_validate_json(store.latest_report(c, cid)["body"])
            rep = pipeline.regenerate_questions(prev, doc, ctx, progress=_progress(cid))
        else:
            js = json.loads(p["jd_struct"]) if p["jd_struct"] else None
            jd_struct = JDStruct.model_validate(js) if js and "error" not in js else None
            rep = pipeline.run(parsing.load_text(p["jd_raw"]), doc, company_ctx=ctx,
                               minutes=p["interview_minutes"] or 60, today=date.today(),
                               progress=_progress(cid), jd_struct=jd_struct)
            if jd_struct is None:
                c.execute("UPDATE positions SET jd_struct=? WHERE id=?", (rep.jd.model_dump_json(), p["id"]))
        store.save_report(c, cid, json.loads(rep.model_dump_json(by_alias=True)), edited_by="system")
        c.execute("UPDATE candidates SET status='done', name=?, pii=?, progress=NULL WHERE id=?",
                  (rep.candidate, json.dumps(doc.pii, ensure_ascii=False), cid))
    except Exception as e:  # noqa: BLE001
        c.execute("UPDATE candidates SET status='failed', error=? WHERE id=?", (f"{type(e).__name__}: {e}", cid))
    c.commit()


@app.delete("/positions/{pid}")
def delete_position(pid: str, x_user: str | None = Header(None)):
    c = conn()
    for cand in c.execute("SELECT id, file_key FROM candidates WHERE position_id=?", (pid,)).fetchall():
        store.delete_candidate(c, cand)
    c.execute("DELETE FROM positions WHERE id=?", (pid,))
    c.commit()
    store.audit(c, _user(x_user), "delete_position", pid)
    return {"ok": True}


@app.post("/positions/{pid}/candidates")
async def upload_resume(pid: str, file: UploadFile = File(...), x_user: str | None = Header(None)):
    c = conn()
    if not c.execute("SELECT 1 FROM positions WHERE id=?", (pid,)).fetchone():
        raise HTTPException(404)
    ext = Path(file.filename or "").suffix.lower()
    if ext not in {".pdf", ".docx", ".md", ".txt"}:
        raise HTTPException(400, "支持 pdf / docx / md / txt")
    cid = store.new_id()
    key = f"{cid}{ext}"
    (store.file_dir() / key).write_bytes(await file.read())
    c.execute("INSERT INTO candidates(id, position_id, name, file_key, status, expire_at, created_at) VALUES (?,?,?,?,?,?,?)",
              (cid, pid, Path(file.filename or "").stem, key, "pending", store.expire_at(), store.now()))
    c.commit()
    store.audit(c, _user(x_user), "upload", cid)
    threading.Thread(target=_run_candidate, args=(cid,), daemon=True).start()
    return {"candidate_id": cid}


@app.get("/positions/{pid}/candidates")
def list_candidates(pid: str):
    c = conn()
    out = []
    for r in c.execute("SELECT * FROM candidates WHERE position_id=? ORDER BY created_at DESC", (pid,)):
        item = {k: r[k] for k in ("id", "name", "status", "error", "progress", "created_at", "expire_at")}
        rep = store.latest_report(c, r["id"])
        if rep:
            b = json.loads(rep["body"])
            item.update(score=b["conclusion"]["score"], decision=b["conclusion"]["decision"],
                        high=sum(d["severity"] == "high" for d in b["doubts"]))
        # 面试状态：有评价看评价结论；只有打分 / 逐字稿 / 备注也算面过
        ev = c.execute("SELECT decision, created_at FROM evaluations WHERE candidate_id=? ORDER BY created_at DESC LIMIT 1",
                       (r["id"],)).fetchone()
        touched = ev or c.execute(
            "SELECT 1 FROM interview_scores s JOIN reports p ON s.report_id=p.id WHERE p.candidate_id=? "
            "UNION SELECT 1 FROM transcripts WHERE candidate_id=? UNION SELECT 1 FROM interview_notes "
            "WHERE candidate_id=? AND note<>'' LIMIT 1", (r["id"], r["id"], r["id"])).fetchone()
        item.update(interviewed=bool(touched), interview_decision=ev["decision"] if ev else None,
                    interviewed_at=ev["created_at"] if ev else None)
        out.append(item)
    return out


def _round(rep) -> int:
    return json.loads(rep["body"]).get("round", 1)


def _report_row(c, cid):
    rep = store.latest_report(c, cid)
    if not rep:
        raise HTTPException(404, "报告尚未生成")
    return rep


@app.get("/candidates/{cid}/report")
def get_report(cid: str, x_user: str | None = Header(None)):
    c = conn()
    rep = _report_row(c, cid)
    cand = c.execute("SELECT * FROM candidates WHERE id=?", (cid,)).fetchone()
    store.audit(c, _user(x_user), "view", cid)
    doc = parsing.load(store.file_dir() / cand["file_key"], mask=False)
    scores = [dict(r) for r in c.execute("SELECT * FROM interview_scores WHERE report_id IN "
                                         "(SELECT id FROM reports WHERE candidate_id=?) ORDER BY created_at", (cid,))]
    evals = [dict(r) for r in c.execute("SELECT * FROM evaluations WHERE candidate_id=? ORDER BY created_at", (cid,))]
    first = c.execute("SELECT MIN(created_at) m FROM reports WHERE candidate_id=? AND json_extract(body,'$.round')=?",
                      (cid, _round(rep))).fetchone()["m"] if _round(rep) > 1 else ""
    tr = c.execute("SELECT * FROM transcripts WHERE candidate_id=? AND created_at>=? ORDER BY created_at DESC LIMIT 1",
                   (cid, first or "")).fetchone()
    return {"id": rep["id"], "version": rep["version"], "report": json.loads(rep["body"]),
            "resume_lines": doc.lines, "scores": scores, "evaluations": evals,
            "summary": json.loads(tr["summary"]) if tr and tr["summary"] else None,
            "transcript": json.loads(tr["body"]) if tr else [],
            "overall_note": store.get_note(c, cid),
            "interviewed_at": (tr["created_at"] if tr else (evals[-1]["created_at"] if evals else None))}


@app.get("/candidates/{cid}/snippet")
def resume_snippet(cid: str, lines: str):
    cand = conn().execute("SELECT * FROM candidates WHERE id=?", (cid,)).fetchone()
    if not cand:
        raise HTTPException(404, "候选人不存在")
    path = store.file_dir() / cand["file_key"]
    nos = [int(x) for x in lines.split(",") if x.strip().isdigit()]
    png = snippet.render(path, parsing.load(path, mask=False), nos)
    if png is None:
        raise HTTPException(404, "没有可截图的原文")
    return Response(png, media_type="image/png", headers={"Cache-Control": "max-age=3600"})


@app.get("/candidates/{cid}/file")
def resume_file(cid: str):
    cand = conn().execute("SELECT * FROM candidates WHERE id=?", (cid,)).fetchone()
    if not cand:
        raise HTTPException(404, "候选人不存在")
    path = store.file_dir() / cand["file_key"]
    types = {".pdf": "application/pdf", ".md": "text/markdown; charset=utf-8", ".txt": "text/plain; charset=utf-8",
             ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"}
    return Response(path.read_bytes(), media_type=types.get(path.suffix.lower(), "application/octet-stream"),
                    headers={"X-Filename": path.suffix.lower()})


def _cand_path(cid: str) -> Path:
    cand = conn().execute("SELECT * FROM candidates WHERE id=?", (cid,)).fetchone()
    if not cand:
        raise HTTPException(404, "候选人不存在")
    return store.file_dir() / cand["file_key"]


@app.get("/candidates/{cid}/pages")
def resume_pages(cid: str):
    return snippet.page_sizes(_cand_path(cid))


@app.get("/candidates/{cid}/pages/{n}.png")
def resume_page(cid: str, n: int):
    path = _cand_path(cid)
    if path.suffix.lower() != ".pdf":
        raise HTTPException(404, "不是 PDF")
    cache = store.DATA / "pages" / f"{cid}-{n}.png"   # 跟简历文件一起存放，删除候选人时清理
    if not cache.exists():
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_bytes(snippet.render_page(path, n))
    return Response(cache.read_bytes(), media_type="image/png", headers={"Cache-Control": "max-age=3600"})


@app.get("/candidates/{cid}/locate")
def resume_locate(cid: str, lines: str):
    cand = conn().execute("SELECT * FROM candidates WHERE id=?", (cid,)).fetchone()
    if not cand:
        raise HTTPException(404, "候选人不存在")
    path = store.file_dir() / cand["file_key"]
    nos = [int(x) for x in lines.split(",") if x.strip().isdigit()]
    return snippet.locate(path, parsing.load(path, mask=False), nos)


@app.post("/candidates/{cid}/regenerate")
def regenerate(cid: str, stage: str = "all", x_user: str | None = Header(None)):
    c = conn()
    store.audit(c, _user(x_user), f"regenerate:{stage}", cid)
    threading.Thread(target=_run_candidate, args=(cid, stage == "questions"), daemon=True).start()
    return {"ok": True}


@app.post("/candidates/{cid}/next-round")
def next_round(cid: str, x_user: str | None = Header(None)):
    c = conn()
    _report_row(c, cid)
    store.audit(c, _user(x_user), "next_round", cid)
    threading.Thread(target=_run_candidate, args=(cid, False, True), daemon=True).start()
    return {"ok": True}


@app.patch("/reports/{rid}")
def edit_report(rid: str, body: dict, x_user: str | None = Header(None)):
    c = conn()
    row = c.execute("SELECT * FROM reports WHERE id=?", (rid,)).fetchone()
    if not row:
        raise HTTPException(404)
    merged = {**json.loads(row["body"]), **body}
    Report.model_validate(merged)
    new = store.save_report(c, row["candidate_id"], merged, edited_by=_user(x_user))
    store.audit(c, _user(x_user), "edit_report", new)
    return {"id": new}


@app.get("/reports/{rid}/export")
def export(rid: str, format: str = "md", answers: bool = True, x_user: str | None = Header(None)):
    c = conn()
    row = c.execute("SELECT * FROM reports WHERE id=?", (rid,)).fetchone()
    if not row:
        raise HTTPException(404)
    cand = c.execute("SELECT * FROM candidates WHERE id=?", (row["candidate_id"],)).fetchone()
    rep = Report.model_validate_json(row["body"])
    md = render.markdown(rep, json.loads(cand["pii"] or "{}"), with_answers=answers)
    store.audit(c, _user(x_user), f"export:{format}", rid)
    name = f"{rep.candidate}-{'一面准备' if answers else '面试记录表'}"
    from urllib.parse import quote
    if format == "docx":
        return Response(render.docx_bytes(md), media_type="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                        headers={"Content-Disposition": f"attachment; filename*=UTF-8''{quote(name)}.docx"})
    if format == "html":
        return Response(render_html.html(rep, json.loads(cand["pii"] or "{}"), with_answers=answers),
                        media_type="text/html; charset=utf-8",
                        headers={"Content-Disposition": f"attachment; filename*=UTF-8''{quote(name)}.html"})
    if format != "md":
        raise HTTPException(400, "支持 md / docx / html")
    return Response(md, media_type="text/markdown; charset=utf-8",
                    headers={"Content-Disposition": f"attachment; filename*=UTF-8''{quote(name)}.md"})


class ScoreIn(BaseModel):
    question_id: str
    score: str | None = None   # excellent / pass / fail
    note: str = ""


@app.post("/reports/{rid}/scores")
def add_scores(rid: str, items: list[ScoreIn], x_user: str | None = Header(None)):
    c = conn()
    for s in items:
        c.execute("DELETE FROM interview_scores WHERE report_id=? AND question_id=?", (rid, s.question_id))
        c.execute("INSERT INTO interview_scores VALUES (?,?,?,?,?,?,?)",
                  (store.new_id(), rid, s.question_id, s.score, s.note, _user(x_user), store.now()))
    c.commit()
    return {"ok": True}


class EvalIn(BaseModel):
    round: int = 1
    overall_note: str = ""


@app.post("/candidates/{cid}/evaluation")
def make_evaluation(cid: str, body: EvalIn, x_user: str | None = Header(None)):
    c = conn()
    rep = _report_row(c, cid)
    scores = [dict(r) for r in c.execute("SELECT * FROM interview_scores WHERE report_id=?", (rep["id"],))]
    if body.overall_note:
        store.save_note(c, cid, body.overall_note)
    ev = evaluation.generate(Report.model_validate_json(rep["body"]), scores, body.overall_note or store.get_note(c, cid))
    c.execute("INSERT INTO evaluations VALUES (?,?,?,?,?,?)",
              (store.new_id(), cid, _round(rep), ev.decision, ev.comment, store.now()))
    c.commit()
    store.audit(c, _user(x_user), "evaluation", cid)
    return ev.model_dump()


class Utterance(BaseModel):
    speaker: str
    text: str
    question_id: str = ""
    at: float = 0


class SummaryIn(BaseModel):
    transcript: list[Utterance]
    overall_note: str = ""


@app.post("/candidates/{cid}/summary")
def make_summary(cid: str, body: SummaryIn, x_user: str | None = Header(None)):
    c = conn()
    rep = _report_row(c, cid)
    scores = [dict(r) for r in c.execute("SELECT * FROM interview_scores WHERE report_id=?", (rep["id"],))]
    tr = [u.model_dump() for u in body.transcript]
    if body.overall_note:
        store.save_note(c, cid, body.overall_note)
    sm = evaluation.summarize(Report.model_validate_json(rep["body"]), scores, tr, body.overall_note or store.get_note(c, cid))
    c.execute("INSERT INTO transcripts VALUES (?,?,?,?,?)",
              (store.new_id(), cid, json.dumps(tr, ensure_ascii=False), sm.model_dump_json(), store.now()))
    c.execute("INSERT INTO evaluations VALUES (?,?,?,?,?,?)",
              (store.new_id(), cid, _round(rep), sm.decision, sm.comment, store.now()))
    c.commit()
    store.audit(c, _user(x_user), "summary", cid)
    return sm.model_dump()


@app.post("/candidates/{cid}/transcript")
def save_transcript(cid: str, body: SummaryIn):
    """退出面试时先存逐字稿（还没生成总结）；之后生成总结会再存一条带总结的。"""
    c = conn()
    c.execute("INSERT INTO transcripts VALUES (?,?,?,?,?)",
              (store.new_id(), cid, json.dumps([u.model_dump() for u in body.transcript], ensure_ascii=False), None, store.now()))
    c.commit()
    return {"ok": True}


class DecisionIn(BaseModel):
    decision: str      # 通过 / 待定 / 不通过


@app.put("/candidates/{cid}/decision")
def set_decision(cid: str, body: DecisionIn, x_user: str | None = Header(None)):
    """手动改面试结论：改最近一条评价；还没有评价就新建一条（评价文字留空）。"""
    if body.decision not in ("通过", "待定", "不通过"):
        raise HTTPException(400, "结论只能是 通过 / 待定 / 不通过")
    c = conn()
    rnd = _round(_report_row(c, cid))
    ev = c.execute("SELECT id FROM evaluations WHERE candidate_id=? AND round=? ORDER BY created_at DESC LIMIT 1", (cid, rnd)).fetchone()
    if ev:
        c.execute("UPDATE evaluations SET decision=? WHERE id=?", (body.decision, ev["id"]))
    else:
        c.execute("INSERT INTO evaluations VALUES (?,?,?,?,?,?)", (store.new_id(), cid, rnd, body.decision, "", store.now()))
    c.commit()
    store.audit(c, _user(x_user), f"decision:{body.decision}", cid)
    return {"ok": True}


@app.delete("/candidates/{cid}")
def delete_candidate(cid: str, x_user: str | None = Header(None)):
    c = conn()
    r = c.execute("SELECT id, file_key FROM candidates WHERE id=?", (cid,)).fetchone()
    if r:
        store.delete_candidate(c, r)
        c.commit()
        store.audit(c, _user(x_user), "delete_candidate", cid)
    return {"ok": True}


class LiveIn(BaseModel):
    question_id: str
    transcript: list[Utterance]


@app.post("/candidates/{cid}/live-hint")
def make_live_hint(cid: str, body: LiveIn):
    rep = _report_row(conn(), cid)
    return evaluation.live_hint(Report.model_validate_json(rep["body"]), body.question_id,
                                [u.model_dump() for u in body.transcript]).model_dump()


def _compare_rows(c, ids: list[str]) -> tuple[list[dict], str, list[dict]]:
    """对比表数据：每人的匹配分、结论、各条 JD 要求的匹配、面试打分和评价"""
    rows, position, reqs = [], "", []
    for cid in ids:
        cand = c.execute("SELECT * FROM candidates WHERE id=?", (cid,)).fetchone()
        rep = store.latest_report(c, cid)
        if not cand or not rep:
            continue
        b = json.loads(rep["body"])
        position = position or b["position"]
        if not reqs:
            reqs = [{"id": r["id"], "text": r["text"], "level": r["level"], "weight": r["weight"]}
                    for r in b["jd"]["requirements"] if r["level"] != "duty"]
        scores = [dict(x) for x in c.execute("SELECT score, note FROM interview_scores WHERE report_id=?", (rep["id"],))]
        ev = c.execute("SELECT decision, comment FROM evaluations WHERE candidate_id=? ORDER BY created_at DESC LIMIT 1", (cid,)).fetchone()
        tr = c.execute("SELECT summary FROM transcripts WHERE candidate_id=? AND summary IS NOT NULL ORDER BY created_at DESC LIMIT 1", (cid,)).fetchone()
        sm = json.loads(tr["summary"]) if tr else {}
        cnt = {k: sum(1 for s in scores if s["score"] == k) for k in ("excellent", "pass", "fail", "skip")}
        rows.append({"id": cid, "name": cand["name"] or b["candidate"], "score": b["conclusion"]["score"],
                     "decision": b["conclusion"]["decision"], "summary": b["conclusion"]["summary"],
                     "high_doubts": sum(d["severity"] == "high" for d in b["doubts"]),
                     "verdicts": {m["req_id"]: m["verdict"] for m in b["match"]},
                     "interview_decision": ev["decision"] if ev else None, "interview_comment": ev["comment"] if ev else "",
                     "score_counts": cnt, "highlights": sm.get("highlights", []), "concerns": sm.get("concerns", []),
                     "note": store.get_note(c, cid)})
    return rows, position, reqs


class CompareIn(BaseModel):
    candidate_ids: list[str]
    ai: bool = False


@app.post("/compare")
def compare_candidates(body: CompareIn):
    rows, position, reqs = _compare_rows(conn(), body.candidate_ids)
    out = {"position": position, "requirements": reqs, "candidates": rows, "ai": None}
    if body.ai and rows:
        brief = [{k: r[k] for k in ("name", "score", "decision", "summary", "high_doubts", "interview_decision",
                                     "interview_comment", "score_counts", "highlights", "concerns", "note")} |
                 {"JD 缺失": [q["text"] for q in reqs if r["verdicts"].get(q["id"]) == "missing" and q["level"] == "must"]}
                 for r in rows]
        out["ai"] = evaluation.compare(brief, position).model_dump()
    return out


def _share_data(c, cid: str) -> dict:
    rep = _report_row(c, cid)
    b = json.loads(rep["body"])
    rnd = b.get("round", 1)
    ev = c.execute("SELECT decision, comment FROM evaluations WHERE candidate_id=? AND round=? ORDER BY created_at DESC LIMIT 1",
                   (cid, rnd)).fetchone()
    tr = c.execute("SELECT summary FROM transcripts WHERE candidate_id=? AND summary IS NOT NULL ORDER BY created_at DESC LIMIT 1",
                   (cid,)).fetchone()
    sm = json.loads(tr["summary"]) if tr else {}
    scores = [r["score"] for r in c.execute("SELECT score FROM interview_scores WHERE report_id=?", (rep["id"],))]
    return {"candidate": b["candidate"], "position": b["position"], "round": rnd, "score": b["conclusion"]["score"],
            "decision": ev["decision"] if ev else "", "comment": ev["comment"] if ev else "",
            "highlights": sm.get("highlights", [])[:4], "concerns": sm.get("concerns", [])[:4],
            "counts": {k: scores.count(k) for k in ("excellent", "pass", "fail", "skip")}, "note": store.get_note(c, cid)}


@app.get("/candidates/{cid}/share-preview")
def share_preview(cid: str):
    return lark.card(_share_data(conn(), cid))


@app.post("/candidates/{cid}/share-lark")
def share_lark(cid: str, x_user: str | None = Header(None)):
    c = conn()
    try:
        lark.send(lark.card(_share_data(c, cid)))
    except lark.LarkError as e:
        raise HTTPException(400, str(e))
    store.audit(c, _user(x_user), "share_lark", cid)
    return {"ok": True}


@app.get("/insights")
def insights():
    """面试官自我复盘：打分分布、和 AI 建议比偏宽 / 偏严、各环节跳过率、漏问的要点、面试时长"""
    c = conn()
    rank = {"excellent": 3, "pass": 2, "fail": 1}
    dist = {"excellent": 0, "pass": 0, "fail": 0, "skip": 0}
    agree = {"same": 0, "looser": 0, "stricter": 0}
    loose_q, strict_q = [], []
    sec: dict[str, dict] = {}
    missed: dict[str, int] = {}
    durations, decisions = [], {"通过": 0, "待定": 0, "不通过": 0}
    interviewed = 0
    for cand in c.execute("SELECT id, name FROM candidates WHERE status='done'").fetchall():
        rep = store.latest_report(c, cand["id"])
        if not rep:
            continue
        b = json.loads(rep["body"])
        qs = {q["id"]: q for q in b["questions"]}
        scores = {r["question_id"]: r["score"] for r in c.execute(
            "SELECT question_id, score FROM interview_scores s JOIN reports p ON s.report_id=p.id WHERE p.candidate_id=?", (cand["id"],))}
        ev = c.execute("SELECT decision FROM evaluations WHERE candidate_id=? ORDER BY created_at DESC LIMIT 1", (cand["id"],)).fetchone()
        tr = c.execute("SELECT body, summary FROM transcripts WHERE candidate_id=? ORDER BY created_at DESC LIMIT 1", (cand["id"],)).fetchone()
        if not (scores or ev or tr):
            continue
        interviewed += 1
        if ev and ev["decision"] in decisions:
            decisions[ev["decision"]] += 1
        for qid, q in qs.items():
            st = sec.setdefault(q["section"], {"asked": 0, "skipped": 0, "total": 0})
            st["total"] += 1
            v = scores.get(qid)
            if v in dist:
                dist[v] += 1
            if v == "skip":
                st["skipped"] += 1
            elif v:
                st["asked"] += 1
        if tr:
            body = json.loads(tr["body"] or "[]")
            if body:
                durations.append(max(u.get("at", 0) for u in body) / 60)
            sm = json.loads(tr["summary"]) if tr["summary"] else {}
            for r in sm.get("questions", []):
                mine, ai = scores.get(r["question_id"]), r.get("suggested_score")
                if mine in rank and ai in rank:
                    k = "same" if rank[mine] == rank[ai] else ("looser" if rank[mine] > rank[ai] else "stricter")
                    agree[k] += 1
                    qtext = f'{cand["name"]}：{qs.get(r["question_id"], {}).get("question", "")[:30]}…'
                    (loose_q if k == "looser" else strict_q if k == "stricter" else []).append(qtext)
                for m in r.get("missed", []):
                    key = qs.get(r["question_id"], {}).get("section", "其他")
                    missed[key] = missed.get(key, 0) + 1
    graded = agree["looser"] + agree["stricter"] + agree["same"]
    tips = []
    if graded >= 3:
        if agree["looser"] > agree["stricter"] and agree["looser"] / graded > 0.3:
            tips.append("你的打分比 AI 依据逐字稿给的建议整体偏宽，给「优秀 / 合格」前可以再对一下关键要点")
        elif agree["stricter"] > agree["looser"] and agree["stricter"] / graded > 0.3:
            tips.append("你的打分比 AI 依据逐字稿给的建议整体偏严，可以再看看是不是有答到要点但表达不够流畅的情况")
    for k, st in sec.items():
        if st["total"] >= 3 and st["skipped"] / st["total"] > 0.4:
            tips.append(f"「{k}」环节跳过了 {st['skipped']}/{st['total']} 题，这类题经常问不到，可以考虑减少或提前问")
    if missed:
        k = max(missed, key=missed.get)
        tips.append(f"候选人没答到的要点最多出现在「{k}」环节（{missed[k]} 处），这里的追问可以更深入")
    if durations and len(durations) >= 2:
        tips.append(f"有逐字稿的面试平均 {sum(durations) / len(durations):.0f} 分钟")
    return {"interviewed": interviewed, "decisions": decisions, "score_dist": dist, "agree": agree,
            "looser_examples": loose_q[:5], "stricter_examples": strict_q[:5],
            "sections": [{"section": k, **v} for k, v in sec.items()],
            "missed_by_section": missed, "avg_minutes": round(sum(durations) / len(durations), 1) if durations else None,
            "tips": tips}


class OverallNoteIn(BaseModel):
    note: str


@app.put("/candidates/{cid}/note")
def put_note(cid: str, body: OverallNoteIn):
    store.save_note(conn(), cid, body.note)
    return {"ok": True}


class NoteIn(BaseModel):
    question_id: str
    transcript: list[Utterance]


@app.post("/candidates/{cid}/question-note")
def make_question_note(cid: str, body: NoteIn):
    rep = _report_row(conn(), cid)
    note = evaluation.question_note(Report.model_validate_json(rep["body"]), body.question_id,
                                    [u.model_dump() for u in body.transcript])
    return {"note": note}


def _settings_out() -> dict:
    s = config.get()
    k = s.pop("api_key") or ""
    t = s.pop("hibob_token") or ""
    cal = s.pop("calendar_ics_url") or ""
    hook = s.pop("lark_webhook") or ""
    s.pop("lark_secret", None)
    s["lark_webhook_hint"] = ("已设置 …" + hook[-6:]) if hook else ""
    s["calendar_url_hint"] = ("已设置 …" + cal[-10:]) if cal else ""
    s.pop("hibob_oauth", None)
    return {**s, "api_key_hint": (k[:7] + "…" + k[-4:]) if k else "", "hibob_token_hint": ("…" + t[-4:]) if t else "",
            "default_fast": llm.SONNET, "default_strong": llm.OPUS}


@app.get("/settings")
def get_settings():
    return _settings_out()


@app.put("/settings")
def put_settings(body: dict):
    """只改传进来的字段；api_key 不传 = 不改，传空串 = 清除。"""
    body = {k: (v.strip() if isinstance(v, str) else v) for k, v in body.items()}
    old = config.get()
    # 换了邮箱、员工 ID 没手动改时，清掉缓存的员工 ID，下次重新查
    if body.get("hibob_email", old["hibob_email"]) != old["hibob_email"] and \
            body.get("hibob_employee_id", old["hibob_employee_id"]) == old["hibob_employee_id"]:
        body["hibob_employee_id"] = ""
    config.save(body)
    llm.reset_client()
    return _settings_out()


@app.post("/settings/test")
def test_settings():
    model = llm.resolve_model(llm.SONNET)
    try:
        llm.client().messages.create(model=model, max_tokens=16, messages=[{"role": "user", "content": "ping"}])
    except Exception as e:  # noqa: BLE001
        raise HTTPException(400, f"连接失败：{e}")
    return {"ok": True, "model": model}


# ---------- HiBob ----------


def _hibob(fn):
    try:
        return fn()
    except hibob.HiBobError as e:
        raise HTTPException(400, str(e))
    except httpx.HTTPError as e:
        raise HTTPException(400, f"连不上 HiBob：{e}")


def _links(c, kind: str) -> dict:
    return {r["hibob_id"]: r["local_id"] for r in c.execute("SELECT * FROM hibob_links WHERE kind=?", (kind,))}


@app.post("/hibob/test")
def hibob_test():
    me = _hibob(hibob.my_id)
    n = _hibob(lambda: len(hibob.interviews()))
    return {"ok": True, "employee_id": me, "interviews": n}


@app.get("/hibob/openings")
def hibob_openings():
    if hibob_mcp.connected():
        return []      # 个人账号接口拿不到岗位 JD，岗位仍在 App 里手动建
    c = conn()
    links = _links(c, "opening")
    existing = {r["id"] for r in c.execute("SELECT id FROM positions")}
    return [{**o, "position_id": links.get(o["id"]) if links.get(o["id"]) in existing else None}
            for o in _hibob(hibob.openings)]


class HiBobImport(BaseModel):
    id: str
    title: str
    jd: str


@app.post("/hibob/openings/import")
def hibob_import(body: HiBobImport, x_user: str | None = Header(None)):
    if not body.jd.strip():
        raise HTTPException(400, "这个岗位在 HiBob 里没有招聘广告（Job Ad），拿不到 JD，请手动新建岗位并粘贴 JD")
    res = create_position(PositionIn(title=body.title, jd_raw=body.jd), x_user)
    c = conn()
    c.execute("INSERT OR REPLACE INTO hibob_links VALUES ('opening', ?, ?)", (body.id, res["id"]))
    c.commit()
    return res


@app.get("/hibob/pipeline")
def hibob_pipeline():
    """个人 Bob 账号：在招岗位和应聘人，对上本地的岗位（按名称）和候选人（按姓名）"""
    c = conn()
    out = []
    for o in _mcp(hibob_mcp.pipeline):
        p = c.execute("SELECT id FROM positions WHERE title=? OR title LIKE ? ORDER BY updated_at DESC",
                      (o["title"], f'{o["title"]}%')).fetchone()
        pid = p["id"] if p else None
        apps = []
        for x in o["applicants"]:
            key = x["name"].replace(" ", "")
            r = c.execute("SELECT id FROM candidates WHERE position_id=? AND replace(name,' ','') LIKE ? ORDER BY created_at DESC",
                          (pid, f"%{key}%")).fetchone() if pid and key else None
            ev = c.execute("SELECT decision FROM evaluations WHERE candidate_id=? ORDER BY created_at DESC LIMIT 1",
                           (r["id"],)).fetchone() if r else None
            apps.append({**x, "candidate_id": r["id"] if r else None, "local_decision": ev["decision"] if ev else None})
        out.append({**o, "position_id": pid, "applicants": apps})
    return out


@app.get("/hibob/interviews")
def hibob_interviews():
    c = conn()
    if hibob_mcp.connected():
        # 个人 Bob 账号：只按候选人姓名匹配本地已有的候选人
        out = []
        for i in _mcp(hibob_mcp.my_interviews):
            r = c.execute("SELECT id, position_id FROM candidates WHERE name LIKE ? ORDER BY created_at DESC",
                          (f'%{i["candidate_name"]}%',)).fetchone() if i["candidate_name"] else None
            out.append({**i, "position_id": r["position_id"] if r else None, "candidate_id": r["id"] if r else None})
        return out
    links = _links(c, "opening")
    out = []
    for i in _hibob(hibob.interviews):
        pid = links.get(i["job_opening_id"])
        cid = None
        if pid and i["candidate_name"]:
            r = c.execute("SELECT id FROM candidates WHERE position_id=? AND (name=? OR name LIKE ?) ORDER BY created_at DESC",
                          (pid, i["candidate_name"], f'%{i["candidate_name"]}%')).fetchone()
            cid = r["id"] if r else None
        out.append({**i, "position_id": pid, "candidate_id": cid})
    return out


# ---------- HiBob（个人 Bob 账号，经官方 MCP） ----------


def _mcp(fn):
    try:
        return fn()
    except hibob_mcp.MCPError as e:
        raise HTTPException(400, str(e))
    except httpx.HTTPError as e:
        raise HTTPException(400, f"连不上 Bob：{e}")


@app.post("/hibob/mcp/login")
def hibob_mcp_login(request: Request):
    redirect = f"{request.url.scheme}://{request.url.netloc}/hibob/mcp/callback"
    return {"url": _mcp(lambda: hibob_mcp.login_url(redirect))}


@app.get("/hibob/mcp/callback", response_class=HTMLResponse)
def hibob_mcp_callback(state: str = "", code: str = "", error: str = ""):
    msg = "登录成功，可以关掉这个页面，回到「面搭子」。"
    try:
        if error or not code:
            raise hibob_mcp.MCPError(error or "Bob 没有返回授权码")
        hibob_mcp.finish_login(state, code)
        try:
            me = hibob_mcp.call("commons_getCurrentUserEssentials")
            cfg = config.get()["hibob_oauth"]
            cfg["user"] = json.dumps(me, ensure_ascii=False)[:2000]
            config.save({"hibob_oauth": cfg})
        except Exception:  # noqa: BLE001 —— 拿不到个人信息不影响登录
            pass
    except (hibob_mcp.MCPError, httpx.HTTPError) as e:
        msg = f"登录失败：{e}"
    return (f"<html><body style='font:16px -apple-system;display:grid;place-items:center;height:90vh;color:#333'>"
            f"<div>{msg}</div></body></html>")


@app.get("/hibob/mcp/status")
def hibob_mcp_status():
    t = config.get().get("hibob_oauth") or {}
    return {"connected": hibob_mcp.connected(), "user": t.get("user", "")}


@app.post("/hibob/mcp/logout")
def hibob_mcp_logout():
    hibob_mcp.logout()
    return {"ok": True}


@app.get("/hibob/mcp/raw")
def hibob_mcp_raw(tool: str = "__list__"):
    """调试用：直接看某个 Bob 工具返回什么"""
    args = {"type": "hiring_my_interviews", "configuration": {}} if tool == "myInterviews_getMyInterviews" else {}
    return _mcp(lambda: hibob_mcp.call(tool, args))


def _cal_cands(c) -> list[dict]:
    return [{"id": r["id"], "name": r["name"] or "", "position_id": r["position_id"],
             "key": re.sub(r"\s|\d+年$", "", (r["name"] or "")).lower()}
            for r in c.execute("SELECT id, name, position_id FROM candidates")]


@app.post("/calendar/match")
def calendar_match(events: list[dict]):
    return calendar_ics.match(events, _cal_cands(conn()))


@app.get("/calendar/events")
def calendar_events():
    c = conn()
    cands = [{"id": r["id"], "name": r["name"] or "", "position_id": r["position_id"],
              "key": re.sub(r"\s|\d+年$", "", (r["name"] or "")).lower()}
             for r in c.execute("SELECT id, name, position_id FROM candidates")]
    try:
        return calendar_ics.upcoming(cands)
    except calendar_ics.CalendarError as e:
        raise HTTPException(400, str(e))


@app.get("/", response_class=HTMLResponse)
def index():
    return (Path(__file__).parent / "static" / "index.html").read_text(encoding="utf-8")
