#!/usr/bin/env python3
"""ops-mall 运维知识库命令行。

  python kb.py index  [--docs runbooks] [--rebuild]   切分 + 向量化 + 入库（只处理有变化的文档）
  python kb.py search "问题"                          只检索，看召回了哪些片段（不调大模型）
  python kb.py ask    "问题" [--push wecom|dingtalk]  检索 + 生成回答，附引用来源
  python kb.py chat                                   交互式连续提问
  python kb.py eval   [--file eval/questions.json]    用标注好的问题测召回率
  python kb.py stats                                  看库里有多少文档、片段

配置全部来自环境变量，见 .env.example。
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path

import kb_core
from kb_store import Store

HERE = Path(__file__).resolve().parent


@dataclass
class Settings:
    db_path: str
    docs_dir: str
    top_k: int
    min_score: float
    keyword_weight: float
    chunk_size: int
    chunk_overlap: int
    redact_before_embed: bool

    @classmethod
    def from_env(cls, env=os.environ) -> "Settings":
        return cls(
            db_path=env.get("KB_DB_PATH", str(HERE / "kb.sqlite3")),
            docs_dir=env.get("KB_DOCS_DIR", str(HERE / "runbooks")),
            top_k=int(env.get("KB_TOP_K", "4")),
            min_score=float(env.get("KB_MIN_SCORE", "0.35")),
            keyword_weight=float(env.get("KB_KEYWORD_WEIGHT", "0.2")),
            chunk_size=int(env.get("KB_CHUNK_SIZE", "800")),
            chunk_overlap=int(env.get("KB_CHUNK_OVERLAP", "100")),
            redact_before_embed=env.get("KB_REDACT_BEFORE_EMBED", "true").lower() == "true",
        )


# ---------------------------------------------------------------- 业务流程（可测试，llm 可以换成假的）


def index_docs(store: Store, llm, settings: Settings, embed_model: str, rebuild: bool = False, log=print) -> dict:
    docs_root = Path(settings.docs_dir)
    if not docs_root.is_dir():
        raise FileNotFoundError(f"文档目录不存在：{docs_root}")
    if rebuild:
        for src in store.sources():
            store.delete_doc(src)
        store.set_meta("embedding_model", "")
    store.check_model(embed_model)

    seen, changed, skipped = set(), 0, 0
    for path in kb_core.iter_markdown_files(docs_root):
        source = path.relative_to(docs_root.parent).as_posix()
        seen.add(source)
        text = path.read_text(encoding="utf-8")
        sha = kb_core.file_sha256(text)
        if store.doc_sha(source) == sha:
            skipped += 1
            continue
        chunks = kb_core.chunk_document(source, text, settings.chunk_size, settings.chunk_overlap)
        inputs = [kb_core.embed_text(c) for c in chunks]
        if settings.redact_before_embed:
            inputs = [kb_core.redact(t) for t in inputs]
        vectors = llm.embed(inputs) if inputs else []
        store.replace_doc(source, sha, chunks, vectors)
        changed += 1
        log(f"  已索引 {source}：{len(chunks)} 个片段")

    removed = 0
    for src in store.sources():  # 文件删了，库里也要删，否则会检索到已经作废的 Runbook
        if src not in seen:
            store.delete_doc(src)
            removed += 1
            log(f"  已删除 {src}（文件不存在了）")
    store.set_meta("embedding_model", embed_model)
    return {"changed": changed, "skipped": skipped, "removed": removed, **store.stats()}


def search(store: Store, llm, settings: Settings, question: str):
    items = store.all_chunks()
    if not items:
        raise RuntimeError("知识库是空的，先执行 python kb.py index")
    qvec = llm.embed([kb_core.redact(question)])[0]
    return kb_core.rank(question, qvec, items, settings.top_k, settings.keyword_weight)


def answer(store: Store, llm, settings: Settings, question: str) -> dict:
    hits = search(store, llm, settings, question)
    if not kb_core.should_answer(hits, settings.min_score):
        return {"answer": kb_core.NOT_FOUND_ANSWER, "hits": hits, "llm_called": False}
    messages = kb_core.build_messages(question, hits)
    text = llm.chat(messages)
    return {"answer": text, "hits": hits, "llm_called": True}


def run_eval(store: Store, llm, settings: Settings, cases: list[dict]) -> dict:
    results, misses = [], []
    for case in cases:
        hits = search(store, llm, settings, case["question"])
        got = [c.source for c, _ in hits]
        results.append((case["expect_source"], got))
        if case["expect_source"] not in got:
            misses.append({"question": case["question"], "expect": case["expect_source"], "got": got})
    return {"recall_at_k": kb_core.recall_at_k(results), "total": len(cases), "misses": misses}


# ---------------------------------------------------------------- 命令行


def make_llm(chat: bool, embed: bool):
    from kb_llm import LLMConfig, OpenAICompatLLM

    cfg = LLMConfig.from_env()
    cfg.require(chat=chat, embed=embed)
    return OpenAICompatLLM(cfg), cfg


def print_answer(result: dict):
    print(result["answer"].strip())
    print("\n参考来源：")
    print(kb_core.format_sources(result["hits"]))
    if not result["llm_called"]:
        print("\n（最高相似度低于 KB_MIN_SCORE，未调用大模型）")


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="ops-mall 运维知识库")
    sub = p.add_subparsers(dest="cmd", required=True)
    pi = sub.add_parser("index")
    pi.add_argument("--docs", help="文档目录，默认 runbooks/")
    pi.add_argument("--rebuild", action="store_true", help="清空后全部重建（换 Embedding 模型后必须用）")
    ps = sub.add_parser("search")
    ps.add_argument("question")
    pa = sub.add_parser("ask")
    pa.add_argument("question")
    pa.add_argument("--push", choices=["wecom", "dingtalk"], help="把回答推送到群机器人")
    sub.add_parser("chat")
    pe = sub.add_parser("eval")
    pe.add_argument("--file", default=str(HERE / "eval" / "questions.json"))
    sub.add_parser("stats")
    args = p.parse_args(argv)

    settings = Settings.from_env()
    if getattr(args, "docs", None):
        settings.docs_dir = args.docs
    store = Store(settings.db_path)
    try:
        if args.cmd == "stats":
            print(json.dumps(store.stats(), ensure_ascii=False, indent=2))
            return 0
        need_chat = args.cmd in ("ask", "chat")
        llm, cfg = make_llm(chat=need_chat, embed=True)
        if args.cmd != "index":
            store.check_model(cfg.embed_model)

        if args.cmd == "index":
            print(f"开始索引 {settings.docs_dir}，Embedding 模型 {cfg.embed_model}")
            res = index_docs(store, llm, settings, cfg.embed_model, rebuild=args.rebuild)
            print(json.dumps(res, ensure_ascii=False, indent=2))
        elif args.cmd == "search":
            for i, (c, s) in enumerate(search(store, llm, settings, args.question), 1):
                print(f"[{i}] {s:.3f} {c.source} | {c.heading}\n    {c.text[:120].replace(chr(10), ' ')}...")
        elif args.cmd == "ask":
            result = answer(store, llm, settings, args.question)
            print_answer(result)
            if args.push:
                import notify

                notify.push(args.push, notify.format_answer(args.question, result))
                print(f"\n已推送到 {args.push}")
        elif args.cmd == "chat":
            print("输入问题回车提问，输入 q 退出")
            while True:
                try:
                    q = input("\n问> ").strip()
                except EOFError:
                    break
                if q in ("q", "quit", "exit"):
                    break
                if q:
                    print_answer(answer(store, llm, settings, q))
        elif args.cmd == "eval":
            cases = json.loads(Path(args.file).read_text(encoding="utf-8"))
            res = run_eval(store, llm, settings, cases)
            print(json.dumps(res, ensure_ascii=False, indent=2))
            return 0 if res["recall_at_k"] >= 0.8 else 1
        return 0
    except Exception as e:  # noqa: BLE001 命令行给人看的错误信息，不打堆栈
        print(f"出错了：{e}", file=sys.stderr)
        return 2
    finally:
        store.close()


if __name__ == "__main__":
    sys.exit(main())
