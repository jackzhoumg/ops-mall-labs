"""把回答推送到企业微信 / 钉钉群（只能"发"，不能"收"）。

  企业微信群"消息推送"（原群机器人）：WECOM_WEBHOOK=https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=<KEY>
  钉钉自定义机器人：DINGTALK_WEBHOOK=https://oapi.dingtalk.com/robot/send?access_token=<TOKEN>
                    安全设置选了"加签"的再配 DINGTALK_SECRET=SEC...
两家都限制每个机器人每分钟最多 20 条，markdown 内容按 4000 字节截断。
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import time
import urllib.parse
import urllib.request

import kb_core

MAX_BYTES = 4000


def truncate(text: str, limit: int = MAX_BYTES) -> str:
    raw = text.encode("utf-8")
    if len(raw) <= limit:
        return text
    return raw[: limit - 30].decode("utf-8", errors="ignore") + "\n\n...(内容过长已截断)"


def format_answer(question: str, result: dict) -> str:
    lines = [f"### 运维助手：{question[:60]}", "", result["answer"].strip(), "", "**参考来源**"]
    for i, (chunk, score) in enumerate(result["hits"], 1):
        lines.append(f"> [{i}] {chunk.source}（{chunk.heading}）")
    return truncate(kb_core.redact("\n".join(lines)))


def dingtalk_sign(secret: str, timestamp_ms: int) -> str:
    """钉钉加签：HmacSHA256(secret, f"{timestamp}\\n{secret}") 后 base64，再 URL 编码。"""
    to_sign = f"{timestamp_ms}\n{secret}".encode("utf-8")
    digest = hmac.new(secret.encode("utf-8"), to_sign, hashlib.sha256).digest()
    return urllib.parse.quote_plus(base64.b64encode(digest).decode())


def build_request(kind: str, markdown: str, env=os.environ, now_ms: int | None = None) -> tuple[str, dict]:
    if kind == "wecom":
        url = env.get("WECOM_WEBHOOK", "")
        body = {"msgtype": "markdown", "markdown": {"content": markdown}}
    elif kind == "dingtalk":
        url = env.get("DINGTALK_WEBHOOK", "")
        secret = env.get("DINGTALK_SECRET", "")
        if url and secret:
            ts = now_ms if now_ms is not None else int(time.time() * 1000)
            url = f"{url}&timestamp={ts}&sign={dingtalk_sign(secret, ts)}"
        body = {"msgtype": "markdown", "markdown": {"title": "运维助手", "text": markdown}}
    else:
        raise ValueError(f"unknown kind {kind}")
    if not url:
        raise RuntimeError(f"没有配置 {'WECOM_WEBHOOK' if kind == 'wecom' else 'DINGTALK_WEBHOOK'}")
    return url, body


def post_json(url: str, body: dict, timeout: float = 5.0) -> dict:
    req = urllib.request.Request(url, data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8") or "{}")


def push(kind: str, markdown: str):
    url, body = build_request(kind, markdown)
    resp = post_json(url, body)
    # 两家成功时都返回 errcode=0；HTTP 200 不代表成功（比如关键词不匹配、超频）
    if resp.get("errcode", 0) != 0:
        raise RuntimeError(f"{kind} 返回错误：{resp}")
