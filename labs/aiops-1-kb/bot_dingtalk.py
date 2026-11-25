#!/usr/bin/env python3
"""钉钉企业内部应用机器人（HTTP 回调模式）：群里 @机器人 提问，机器人查知识库后回复。

和 notify.py 的"自定义机器人"不同，自定义机器人只能往群里发，收不到消息；
要"能问能答"，得在钉钉开放平台建一个企业内部应用，开启机器人能力，消息接收模式选 HTTP，
回调地址填 http://<公网可达的地址>:8090/dingtalk/callback。

  DINGTALK_APP_SECRET   应用的 AppSecret，用来校验回调签名（必填）
  BOT_ALLOWED_STAFF_IDS 允许提问的员工 staffId，逗号分隔；留空表示不限制（实验用，生产要配）
  BOT_LISTEN_PORT       默认 8090

没有公网地址时，推荐改用钉钉的 Stream 模式（机器人主动连钉钉，不需要回调地址），见教程 5.6。
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import kb
import kb_core
import notify
from kb_store import Store

APP_SECRET = os.environ.get("DINGTALK_APP_SECRET", "")
ALLOWED = {s.strip() for s in os.environ.get("BOT_ALLOWED_STAFF_IDS", "").split(",") if s.strip()}
PORT = int(os.environ.get("BOT_LISTEN_PORT", "8090"))
MAX_SKEW_MS = 3600 * 1000  # 钉钉要求时间戳和当前时间相差不超过 1 小时
_lock = threading.Lock()  # SQLite 连接和大模型调用串行化，实验够用


def verify_sign(timestamp: str, sign: str, secret: str, now_ms: int | None = None) -> bool:
    """回调签名：base64(HmacSHA256(appSecret, timestamp + "\\n" + appSecret))，和请求头 sign 比较。"""
    if not (timestamp and sign and secret):
        return False
    try:
        ts = int(timestamp)
    except ValueError:
        return False
    now = now_ms if now_ms is not None else int(time.time() * 1000)
    if abs(now - ts) > MAX_SKEW_MS:
        return False
    digest = hmac.new(secret.encode(), f"{timestamp}\n{secret}".encode(), hashlib.sha256).digest()
    return hmac.compare_digest(base64.b64encode(digest).decode(), sign)


def extract_question(payload: dict) -> str:
    content = (payload.get("text") or {}).get("content", "")
    return content.strip()


def handle_question(payload: dict):
    question = extract_question(payload)
    session_url = payload.get("sessionWebhook", "")
    if not question or not session_url:
        return
    settings = kb.Settings.from_env()
    with _lock:
        store = Store(settings.db_path)
        try:
            llm, cfg = kb.make_llm(chat=True, embed=True)
            store.check_model(cfg.embed_model)
            result = kb.answer(store, llm, settings, question)
            text = notify.format_answer(question, result)
        except Exception as e:  # noqa: BLE001
            text = f"运维助手出错了：{type(e).__name__}，请稍后再试或直接联系值班同学。"
        finally:
            store.close()
    body = {"msgtype": "markdown", "markdown": {"title": "运维助手", "text": text},
            "at": {"atUserIds": [payload.get("senderStaffId", "")]}}
    try:
        notify.post_json(session_url, body, timeout=10)
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"event": "reply_failed", "error": str(e)}, ensure_ascii=False), flush=True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # 默认日志太吵，改成一行 JSON
        print(json.dumps({"event": "http", "path": self.path, "msg": fmt % args}, ensure_ascii=False), flush=True)

    def _reply(self, code: int, body: dict):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            return self._reply(200, {"status": "ok"})
        return self._reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/dingtalk/callback":
            return self._reply(404, {"error": "not found"})
        if not verify_sign(self.headers.get("timestamp", ""), self.headers.get("sign", ""), APP_SECRET):
            return self._reply(401, {"error": "bad sign"})
        length = int(self.headers.get("Content-Length", "0"))
        if length > 64 * 1024:
            return self._reply(413, {"error": "too large"})
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return self._reply(400, {"error": "bad json"})
        staff = payload.get("senderStaffId", "")
        if ALLOWED and staff not in ALLOWED:
            return self._reply(200, {"msgtype": "text", "text": {"content": "你没有使用运维助手的权限，请联系运维负责人开通。"}})
        # 大模型回答要几秒到几十秒，先回 200，再异步用 sessionWebhook 回复，避免钉钉回调超时重发
        threading.Thread(target=handle_question, args=(payload,), daemon=True).start()
        print(json.dumps({"event": "question", "staff": staff,
                          "question": kb_core.redact(extract_question(payload))[:100]}, ensure_ascii=False), flush=True)
        return self._reply(200, {})


def main():
    if not APP_SECRET:
        raise SystemExit("请先设置 DINGTALK_APP_SECRET")
    print(f"listening on :{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
