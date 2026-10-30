"""存储：MVP 用 SQLite + 本地目录代替 PostgreSQL + 私有桶，表结构与方案第 5 节一致。"""
from __future__ import annotations

import json
import os
import sqlite3
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import config

DATA = Path(os.getenv("SCREENER_DATA", Path(__file__).resolve().parent.parent / "data"))

SCHEMA = """
CREATE TABLE IF NOT EXISTS positions (
  id TEXT PRIMARY KEY, title TEXT NOT NULL, jd_raw TEXT NOT NULL, jd_struct TEXT,
  company_ctx TEXT, interview_minutes INT DEFAULT 60, created_by TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS candidates (
  id TEXT PRIMARY KEY, position_id TEXT REFERENCES positions(id), name TEXT, file_key TEXT,
  status TEXT, error TEXT, progress TEXT, pii TEXT, expire_at TEXT, created_at TEXT);
CREATE TABLE IF NOT EXISTS reports (
  id TEXT PRIMARY KEY, candidate_id TEXT REFERENCES candidates(id), version INT, body TEXT,
  edited_by TEXT, created_at TEXT);
CREATE TABLE IF NOT EXISTS interview_scores (
  id TEXT PRIMARY KEY, report_id TEXT REFERENCES reports(id), question_id TEXT, score TEXT,
  note TEXT, interviewer TEXT, created_at TEXT);
CREATE TABLE IF NOT EXISTS evaluations (
  id TEXT PRIMARY KEY, candidate_id TEXT REFERENCES candidates(id), round INT, decision TEXT,
  comment TEXT, created_at TEXT);
CREATE TABLE IF NOT EXISTS transcripts (
  id TEXT PRIMARY KEY, candidate_id TEXT REFERENCES candidates(id), body TEXT, summary TEXT,
  created_at TEXT);
CREATE TABLE IF NOT EXISTS interview_notes (
  candidate_id TEXT PRIMARY KEY REFERENCES candidates(id), note TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS hibob_links (
  kind TEXT, hibob_id TEXT, local_id TEXT, PRIMARY KEY (kind, hibob_id));
CREATE TABLE IF NOT EXISTS audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT, actor TEXT, action TEXT, target TEXT);
"""


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def new_id() -> str:
    return str(uuid.uuid4())


def db() -> sqlite3.Connection:
    DATA.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(DATA / "screener.db", check_same_thread=False, timeout=30)
    c.row_factory = sqlite3.Row
    c.executescript(SCHEMA)
    return c


def file_dir() -> Path:
    p = DATA / "files"
    p.mkdir(parents=True, exist_ok=True)
    return p


def expire_at() -> str:
    return (datetime.now(timezone.utc) + timedelta(days=config.get()["retention_days"])).isoformat(timespec="seconds")


def audit(c: sqlite3.Connection, actor: str, action: str, target: str) -> None:
    c.execute("INSERT INTO audit(at, actor, action, target) VALUES (?,?,?,?)", (now(), actor, action, target))
    c.commit()


def purge_expired(c: sqlite3.Connection) -> int:
    rows = c.execute("SELECT id, file_key FROM candidates WHERE expire_at < ?", (now(),)).fetchall()
    for r in rows:
        delete_candidate(c, r)
    c.commit()
    return len(rows)


def delete_candidate(c: sqlite3.Connection, r) -> None:
    """删除候选人及其文件、报告、打分、评价、逐字稿（不 commit）。"""
    if r["file_key"]:
        (file_dir() / r["file_key"]).unlink(missing_ok=True)
    rep_ids = [x["id"] for x in c.execute("SELECT id FROM reports WHERE candidate_id=?", (r["id"],))]
    for rid in rep_ids:
        c.execute("DELETE FROM interview_scores WHERE report_id=?", (rid,))
    c.execute("DELETE FROM reports WHERE candidate_id=?", (r["id"],))
    c.execute("DELETE FROM evaluations WHERE candidate_id=?", (r["id"],))
    c.execute("DELETE FROM transcripts WHERE candidate_id=?", (r["id"],))
    c.execute("DELETE FROM interview_notes WHERE candidate_id=?", (r["id"],))
    for f in (DATA / "pages").glob(f'{r["id"]}-*.png'):
        f.unlink(missing_ok=True)
    c.execute("DELETE FROM candidates WHERE id=?", (r["id"],))




def save_note(c: sqlite3.Connection, candidate_id: str, note: str) -> None:
    c.execute("INSERT INTO interview_notes VALUES (?,?,?) ON CONFLICT(candidate_id) DO UPDATE SET note=excluded.note, "
              "updated_at=excluded.updated_at", (candidate_id, note, now()))
    c.commit()


def get_note(c: sqlite3.Connection, candidate_id: str) -> str:
    r = c.execute("SELECT note FROM interview_notes WHERE candidate_id=?", (candidate_id,)).fetchone()
    return r["note"] if r else ""


def latest_report(c: sqlite3.Connection, candidate_id: str) -> sqlite3.Row | None:
    return c.execute("SELECT * FROM reports WHERE candidate_id=? ORDER BY version DESC LIMIT 1",
                     (candidate_id,)).fetchone()


def save_report(c: sqlite3.Connection, candidate_id: str, body: dict, edited_by: str | None = None) -> str:
    prev = latest_report(c, candidate_id)
    rid = new_id()
    c.execute("INSERT INTO reports VALUES (?,?,?,?,?,?)",
              (rid, candidate_id, (prev["version"] + 1) if prev else 1,
               json.dumps(body, ensure_ascii=False), edited_by, now()))
    c.commit()
    return rid
