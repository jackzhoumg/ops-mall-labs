"""单元测试：不联网，用 FakeLLM 代替真实的 Embedding / Chat 接口。

运行：cd labs/aiops-1-kb && python -m pytest -q
"""
import hashlib
import json
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

import kb  # noqa: E402
import kb_core  # noqa: E402
import notify  # noqa: E402
from bot_dingtalk import verify_sign  # noqa: E402
from kb_store import Store, pack, unpack  # noqa: E402


class FakeLLM:
    """假的大模型：向量 = 关键词哈希到 256 维的词袋，足够让"相关的文档更相似"。"""

    DIM = 256

    def __init__(self, reply="结论：先看后端 [1]"):
        self.reply = reply
        self.embed_calls = 0
        self.chat_calls = []

    def embed(self, texts):
        self.embed_calls += 1
        out = []
        for t in texts:
            v = [0.0] * self.DIM
            for tok in kb_core.keyword_tokens(t):
                h = int(hashlib.md5(tok.encode()).hexdigest(), 16) % self.DIM
                v[h] += 1.0
            out.append(v)
        return out

    def chat(self, messages):
        self.chat_calls.append(messages)
        return self.reply


def settings(tmp_path, **kw):
    s = kb.Settings.from_env({})
    s.db_path = str(tmp_path / "kb.sqlite3")
    s.docs_dir = str(HERE / "runbooks")
    s.min_score = 0.05
    for k, v in kw.items():
        setattr(s, k, v)
    return s


# ---------------------------------------------------------------- 切分


def test_frontmatter_parsed_and_removed():
    meta, body = kb_core.parse_frontmatter("---\ntitle: 测试\nowner: 运维组\n---\n# 标题\n正文")
    assert meta == {"title": "测试", "owner": "运维组"}
    assert body.startswith("# 标题")


def test_split_sections_keeps_heading_path_and_ignores_hash_in_code():
    body = "# A\n介绍\n## B\n```bash\n# 这是注释不是标题\nls\n```\n## C\n内容"
    secs = kb_core.split_sections(body)
    assert [p for p, _ in secs] == ["A", "A > B", "A > C"]
    assert "# 这是注释不是标题" in secs[1][1]


def test_split_long_text_respects_size_and_overlap():
    text = "\n\n".join(f"第{i}段" + "字" * 90 for i in range(10))
    pieces = kb_core.split_long_text(text, max_chars=250, overlap=30)
    assert len(pieces) > 1
    assert all(len(p) <= 250 + 30 + 1 for p in pieces)
    # 后一片的开头带着前一片的结尾
    assert pieces[1].startswith(pieces[0][-30:])


def test_split_long_text_hard_cut_for_huge_paragraph():
    pieces = kb_core.split_long_text("x" * 1000, max_chars=300, overlap=50)
    assert "".join(p[:250] for p in pieces[:-1]).startswith("x" * 250)
    assert all(len(p) <= 351 for p in pieces)


def test_split_long_text_invalid_args():
    with pytest.raises(ValueError):
        kb_core.split_long_text("abc", max_chars=10, overlap=10)


def test_chunk_document_prefixes_title():
    text = (HERE / "runbooks" / "01-nginx-502.md").read_text(encoding="utf-8")
    chunks = kb_core.chunk_document("runbooks/01-nginx-502.md", text, 800, 100)
    assert len(chunks) >= 5
    assert all(c.heading.startswith("商城返回 502") for c in chunks)
    assert [c.index for c in chunks] == list(range(len(chunks)))
    assert chunks[0].chunk_id == "runbooks/01-nginx-502.md#0"


# ---------------------------------------------------------------- 相似度与排序


def test_cosine():
    assert kb_core.cosine([1, 0], [1, 0]) == pytest.approx(1.0)
    assert kb_core.cosine([1, 0], [0, 1]) == pytest.approx(0.0)
    assert kb_core.cosine([0, 0], [1, 1]) == 0.0
    with pytest.raises(ValueError):
        kb_core.cosine([1, 2], [1, 2, 3])


def test_keyword_tokens_mixed_language():
    toks = kb_core.keyword_tokens("Pod 一直 CrashLoopBackOff，返回 502")
    assert {"pod", "crashloopbackoff", "502", "一直"} <= toks


def test_rank_hybrid_prefers_keyword_match():
    a = kb_core.Chunk("a.md", "A", "MySQL 主从延迟 Seconds_Behind_Source")
    b = kb_core.Chunk("b.md", "B", "Nginx 502")
    # 向量完全一样时，关键词决定顺序
    items = [(b, [1.0, 0.0]), (a, [1.0, 0.0])]
    ranked = kb_core.rank("Seconds_Behind_Source 很大", [1.0, 0.0], items, top_k=2, keyword_weight=0.3)
    assert ranked[0][0].source == "a.md"


def test_should_answer_threshold():
    c = kb_core.Chunk("a.md", "A", "x")
    assert kb_core.should_answer([(c, 0.5)], 0.4)
    assert not kb_core.should_answer([(c, 0.3)], 0.4)
    assert not kb_core.should_answer([], 0.1)


# ---------------------------------------------------------------- 脱敏


@pytest.mark.parametrize("raw, leaked", [
    ("password=Sup3rSecret!", "Sup3rSecret!"),
    ("api_key: sk-abcdefghijklmnopqrstuvwxyz123456", "abcdefghijklmnop"),
    ("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.x.y", "eyJhbGci"),
    ("mysql -uroot -pRootPass123 -h 192.168.56.13", "RootPass123"),
    ("MALL_DB_DSN=mall:MallPass123@tcp(127.0.0.1:3306)/mall", "MallPass123"),
    ("联系人 13812345678", "13812345678"),
    ("AK 是 LTAI5tAbcdEfghIjkl", "LTAI5tAbcdEfghIjkl"),
    ("-----BEGIN RSA PRIVATE KEY-----\nMIIabc\n-----END RSA PRIVATE KEY-----", "MIIabc"),
])
def test_redact(raw, leaked):
    out = kb_core.redact(raw)
    assert leaked not in out


def test_redact_keeps_normal_text():
    s = "mysql -uroot -p -e 'SHOW REPLICA STATUS\\G'"
    assert kb_core.redact(s) == s


# ---------------------------------------------------------------- 提示词


def test_build_messages_numbered_sources_and_rules():
    hits = [(kb_core.Chunk("runbooks/a.md", "A > 排查", "看日志 password=abc123"), 0.9),
            (kb_core.Chunk("runbooks/b.md", "B", "重启"), 0.5)]
    msgs = kb_core.build_messages("怎么办", hits)
    assert msgs[0]["role"] == "system" and "不要编造" in msgs[0]["content"]
    user = msgs[1]["content"]
    assert "[1] 来源：runbooks/a.md（A > 排查）" in user
    assert "[2] 来源：runbooks/b.md" in user
    assert "abc123" not in user  # 发出去之前脱敏
    assert user.rstrip().endswith("怎么办")


def test_build_messages_context_limit():
    big = kb_core.Chunk("a.md", "A", "x" * 5000)
    hits = [(big, 0.9), (big, 0.8), (big, 0.7)]
    user = kb_core.build_messages("q", hits, max_context_chars=6000)[1]["content"]
    assert "[1]" in user and "[3]" not in user


# ---------------------------------------------------------------- 存储


def test_pack_roundtrip():
    v = [0.1, -2.5, 3.0]
    assert unpack(pack(v)) == pytest.approx(v)


def test_store_model_check(tmp_path):
    st = Store(tmp_path / "x.db")
    st.set_meta("embedding_model", "model-a")
    st.check_model("model-a")
    with pytest.raises(RuntimeError, match="重建"):
        st.check_model("model-b")
    st.close()


# ---------------------------------------------------------------- 端到端（假模型）


def test_index_is_incremental_and_removes_deleted(tmp_path):
    docs = tmp_path / "runbooks"
    docs.mkdir()
    (docs / "a.md").write_text("# A\nNginx 502 排查", encoding="utf-8")
    (docs / "b.md").write_text("# B\nRedis 不可用", encoding="utf-8")
    s = settings(tmp_path, docs_dir=str(docs))
    st, llm = Store(s.db_path), FakeLLM()
    r1 = kb.index_docs(st, llm, s, "fake", log=lambda *_: None)
    assert r1["changed"] == 2 and r1["documents"] == 2
    r2 = kb.index_docs(st, llm, s, "fake", log=lambda *_: None)
    assert r2["changed"] == 0 and r2["skipped"] == 2
    (docs / "b.md").unlink()
    r3 = kb.index_docs(st, llm, s, "fake", log=lambda *_: None)
    assert r3["removed"] == 1 and st.sources() == ["runbooks/a.md"]
    st.close()


def test_answer_calls_llm_with_context(tmp_path):
    s = settings(tmp_path)
    st, llm = Store(s.db_path), FakeLLM()
    kb.index_docs(st, llm, s, "fake", log=lambda *_: None)
    res = kb.answer(st, llm, s, "Redis 挂了为什么整个商城都 503")
    assert res["llm_called"]
    assert res["hits"][0][0].source == "runbooks/05-redis-down-site-503.md"
    assert "参考资料" in llm.chat_calls[0][1]["content"]
    st.close()


def test_answer_refuses_when_nothing_relevant(tmp_path):
    s = settings(tmp_path, min_score=0.99)
    st, llm = Store(s.db_path), FakeLLM()
    kb.index_docs(st, llm, s, "fake", log=lambda *_: None)
    res = kb.answer(st, llm, s, "今天中午吃什么")
    assert not res["llm_called"]
    assert res["answer"] == kb_core.NOT_FOUND_ANSWER
    assert llm.chat_calls == []
    st.close()


def test_eval_recall_with_fake_embeddings(tmp_path):
    s = settings(tmp_path)
    st, llm = Store(s.db_path), FakeLLM()
    kb.index_docs(st, llm, s, "fake", log=lambda *_: None)
    cases = json.loads((HERE / "eval" / "questions.json").read_text(encoding="utf-8"))
    res = kb.run_eval(st, llm, s, cases)
    # 词袋假模型都能做到 80% 以上，真模型应该更高
    assert res["recall_at_k"] >= 0.8, res["misses"]
    st.close()


def test_recall_at_k():
    assert kb_core.recall_at_k([("a", ["a", "b"]), ("c", ["a"])]) == 0.5
    assert kb_core.recall_at_k([]) == 0.0


# ---------------------------------------------------------------- 机器人


def test_dingtalk_push_sign_and_body():
    env = {"DINGTALK_WEBHOOK": "https://oapi.dingtalk.com/robot/send?access_token=T", "DINGTALK_SECRET": "SECabc"}
    url, body = notify.build_request("dingtalk", "hi", env=env, now_ms=1700000000000)
    assert "timestamp=1700000000000&sign=" in url
    assert body["markdown"]["text"] == "hi"


def test_wecom_body_and_missing_url():
    url, body = notify.build_request("wecom", "hi", env={"WECOM_WEBHOOK": "https://x/send?key=K"})
    assert body == {"msgtype": "markdown", "markdown": {"content": "hi"}}
    with pytest.raises(RuntimeError):
        notify.build_request("wecom", "hi", env={})


def test_truncate_utf8_bytes():
    out = notify.truncate("中" * 3000, limit=4000)
    assert len(out.encode("utf-8")) <= 4000


def test_verify_callback_sign():
    import base64
    import hashlib as h
    import hmac
    secret, ts = "app-secret", "1700000000000"
    sign = base64.b64encode(hmac.new(secret.encode(), f"{ts}\n{secret}".encode(), h.sha256).digest()).decode()
    assert verify_sign(ts, sign, secret, now_ms=1700000001000)
    assert not verify_sign(ts, sign, "wrong", now_ms=1700000001000)
    assert not verify_sign(ts, sign, secret, now_ms=1700000000000 + 2 * 3600 * 1000)  # 过期
    assert not verify_sign("abc", sign, secret)
