"""分析记录和反馈存 SQLite，用来做效果评估：多少条被分析、多少条降级、多少条被标"有用"。"""
from __future__ import annotations

import json
import sqlite3
import threading
import uuid
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS analyses (
    id          TEXT PRIMARY KEY,
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    alertname   TEXT NOT NULL,
    namespace   TEXT NOT NULL,
    severity    TEXT NOT NULL,
    result      TEXT NOT NULL,          -- ok / fallback
    reason      TEXT NOT NULL DEFAULT '',
    llm_ms      INTEGER NOT NULL DEFAULT 0,
    analysis    TEXT NOT NULL DEFAULT '{}'
);
CREATE TABLE IF NOT EXISTS feedback (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    analysis_id TEXT NOT NULL REFERENCES analyses(id),
    vote        TEXT NOT NULL CHECK (vote IN ('up', 'down')),
    note        TEXT NOT NULL DEFAULT '',
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
"""


class Store:
    def __init__(self, path: str):
        if path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.lock = threading.Lock()
        with self.lock:
            self.conn.executescript(SCHEMA)

    @staticmethod
    def new_id() -> str:
        return uuid.uuid4().hex[:12]

    def save(self, rid: str, alertname: str, namespace: str, severity: str, result: str,
             reason: str = "", llm_ms: int = 0, analysis: dict | None = None):
        with self.lock, self.conn:
            self.conn.execute(
                "INSERT INTO analyses(id, alertname, namespace, severity, result, reason, llm_ms, analysis) "
                "VALUES(?,?,?,?,?,?,?,?)",
                (rid, alertname, namespace, severity, result, reason, llm_ms,
                 json.dumps(analysis or {}, ensure_ascii=False)))

    def exists(self, rid: str) -> bool:
        with self.lock:
            return self.conn.execute("SELECT 1 FROM analyses WHERE id = ?", (rid,)).fetchone() is not None

    def add_feedback(self, rid: str, vote: str, note: str = ""):
        with self.lock, self.conn:
            self.conn.execute("INSERT INTO feedback(analysis_id, vote, note) VALUES(?,?,?)", (rid, vote, note[:500]))

    def stats(self) -> dict:
        with self.lock:
            rows = self.conn.execute("SELECT result, COUNT(*) FROM analyses GROUP BY result").fetchall()
            by_result = {r: n for r, n in rows}
            # 每条分析只取最后一次投票，避免一个人点十次
            votes = self.conn.execute(
                "SELECT vote, COUNT(*) FROM (SELECT analysis_id, vote FROM feedback f WHERE id = "
                "(SELECT MAX(id) FROM feedback WHERE analysis_id = f.analysis_id)) GROUP BY vote").fetchall()
            v = {k: n for k, n in votes}
            per_alert = self.conn.execute(
                "SELECT a.alertname, COUNT(DISTINCT a.id), "
                "SUM(CASE WHEN f.vote = 'up' THEN 1 ELSE 0 END), SUM(CASE WHEN f.vote = 'down' THEN 1 ELSE 0 END) "
                "FROM analyses a LEFT JOIN feedback f ON f.analysis_id = a.id GROUP BY a.alertname").fetchall()
            avg_ms = self.conn.execute("SELECT AVG(llm_ms) FROM analyses WHERE result = 'ok'").fetchone()[0]
        up, down = v.get("up", 0), v.get("down", 0)
        return {
            "analyses": sum(by_result.values()), "ok": by_result.get("ok", 0), "fallback": by_result.get("fallback", 0),
            "feedback_up": up, "feedback_down": down,
            "useful_ratio": round(up / (up + down), 3) if up + down else None,
            "avg_llm_ms": int(avg_ms) if avg_ms else None,
            "per_alert": [{"alertname": a, "analyses": n, "up": u or 0, "down": d or 0} for a, n, u, d in per_alert],
        }
