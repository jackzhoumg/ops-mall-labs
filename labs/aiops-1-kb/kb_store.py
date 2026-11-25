"""向量存储：一个 SQLite 文件，向量以 float32 二进制存在 BLOB 列里。

为什么不用 Chroma / pgvector：实验里只有几十到几百个片段，全量算余弦几毫秒就完，
SQLite 是 Python 自带的，不用装任何服务。片段过万、多人共用时换 pgvector（见教程第 3 节）。
"""
from __future__ import annotations

import json
import sqlite3
from array import array
from pathlib import Path

from kb_core import Chunk

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS documents (
    source TEXT PRIMARY KEY,
    sha256 TEXT NOT NULL,
    indexed_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE TABLE IF NOT EXISTS chunks (
    id      TEXT PRIMARY KEY,
    source  TEXT NOT NULL REFERENCES documents(source) ON DELETE CASCADE,
    idx     INTEGER NOT NULL,
    heading TEXT NOT NULL,
    text    TEXT NOT NULL,
    meta    TEXT NOT NULL,
    dim     INTEGER NOT NULL,
    vector  BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chunks_source ON chunks(source);
"""


def pack(vec: list[float]) -> bytes:
    return array("f", vec).tobytes()


def unpack(blob: bytes) -> list[float]:
    a = array("f")
    a.frombytes(blob)
    return a.tolist()


class Store:
    def __init__(self, path: str | Path):
        self.path = str(path)
        self.conn = sqlite3.connect(self.path)
        self.conn.execute("PRAGMA foreign_keys = ON")
        self.conn.executescript(SCHEMA)

    def close(self):
        self.conn.close()

    # ---- 元信息：记录建索引时用的 Embedding 模型和维度，换模型必须重建索引
    def get_meta(self, key: str) -> str | None:
        row = self.conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return row[0] if row else None

    def set_meta(self, key: str, value: str):
        self.conn.execute("INSERT INTO meta(key, value) VALUES(?, ?) "
                          "ON CONFLICT(key) DO UPDATE SET value = excluded.value", (key, value))
        self.conn.commit()

    def check_model(self, model: str):
        """索引是用 A 模型建的，查询却用 B 模型向量化，两边的向量空间不一样，结果全是乱的。"""
        saved = self.get_meta("embedding_model")
        if saved and saved != model:
            raise RuntimeError(
                f"索引是用 {saved} 建的，现在配置的是 {model}。换了 Embedding 模型要重建：python kb.py index --rebuild")

    # ---- 文档
    def doc_sha(self, source: str) -> str | None:
        row = self.conn.execute("SELECT sha256 FROM documents WHERE source = ?", (source,)).fetchone()
        return row[0] if row else None

    def sources(self) -> list[str]:
        return [r[0] for r in self.conn.execute("SELECT source FROM documents ORDER BY source")]

    def delete_doc(self, source: str):
        self.conn.execute("DELETE FROM chunks WHERE source = ?", (source,))
        self.conn.execute("DELETE FROM documents WHERE source = ?", (source,))
        self.conn.commit()

    def replace_doc(self, source: str, sha: str, chunks: list[Chunk], vectors: list[list[float]]):
        """一篇文档的所有片段整体替换，放在一个事务里：中途失败不会留下半篇。"""
        if len(chunks) != len(vectors):
            raise ValueError("chunks and vectors length mismatch")
        with self.conn:
            self.conn.execute("DELETE FROM chunks WHERE source = ?", (source,))
            self.conn.execute("INSERT INTO documents(source, sha256) VALUES(?, ?) "
                              "ON CONFLICT(source) DO UPDATE SET sha256 = excluded.sha256, "
                              "indexed_at = datetime('now')", (source, sha))
            self.conn.executemany(
                "INSERT INTO chunks(id, source, idx, heading, text, meta, dim, vector) VALUES(?,?,?,?,?,?,?,?)",
                [(c.chunk_id, c.source, c.index, c.heading, c.text, json.dumps(c.meta, ensure_ascii=False),
                  len(v), pack(v)) for c, v in zip(chunks, vectors)],
            )

    def all_chunks(self) -> list[tuple[Chunk, list[float]]]:
        rows = self.conn.execute("SELECT source, idx, heading, text, meta, vector FROM chunks ORDER BY source, idx")
        return [(Chunk(source=s, heading=h, text=t, index=i, meta=json.loads(m)), unpack(v))
                for s, i, h, t, m, v in rows]

    def stats(self) -> dict:
        docs = self.conn.execute("SELECT COUNT(*) FROM documents").fetchone()[0]
        chunks = self.conn.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
        dim = self.conn.execute("SELECT MAX(dim) FROM chunks").fetchone()[0]
        return {"documents": docs, "chunks": chunks, "dim": dim,
                "embedding_model": self.get_meta("embedding_model")}
