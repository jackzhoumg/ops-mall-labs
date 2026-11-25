"""把分析结果（或降级后的原始告警）格式化成群消息并推送。"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import time
import urllib.parse

from .aggregator import AlertGroup

MAX_BYTES = 4000  # 企业微信 markdown 上限 4096 字节，留余量
SEV = {"critical": "P1 紧急", "warning": "P2 重要", "info": "P3 提示"}
CONF = {"high": "高", "medium": "中", "low": "低"}


def truncate(text: str, limit: int = MAX_BYTES) -> str:
    raw = text.encode("utf-8")
    if len(raw) <= limit:
        return text
    return raw[: limit - 40].decode("utf-8", errors="ignore") + "\n\n...(内容过长已截断)"


def _header(group: AlertGroup) -> list[str]:
    ann = group.annotations
    return [f"### 【{SEV.get(group.severity, group.severity)}】{group.alertname}",
            f"> 命名空间：{group.namespace or '-'}　告警数：{len(group.alerts)}",
            f"> {ann.get('summary', '')}"]


def format_analysis(group: AlertGroup, analysis: dict, record_id: str, feedback_base: str, suppressed: int = 0) -> str:
    lines = _header(group) + ["", f"**AI 分析**：{analysis['summary']}", ""]
    if analysis["possible_causes"]:
        lines.append("**可能原因**")
        for i, c in enumerate(analysis["possible_causes"], 1):
            lines.append(f"{i}. {c['cause']}（可信度{CONF.get(c['confidence'], c['confidence'])}）")
            if c["evidence"]:
                lines.append(f"> 依据：{c['evidence']}")
    if analysis["steps"]:
        lines += ["", "**排查步骤**"] + [f"{i}. {s}" for i, s in enumerate(analysis["steps"], 1)]
    if analysis["commands"]:
        lines += ["", "**建议命令**"]
        for c in analysis["commands"]:
            mark = "【会改变系统，需人工确认】" if c["risk"] == "change" else ""
            lines.append(f"- {mark}[{c['where']}] `{c['cmd']}`")
    lines += ["", "> AI 建议仅供参考，以实际排查为准。"]
    if suppressed:
        lines.append(f"> 冷却期内另有 {suppressed} 次相同告警未重复分析。")
    if feedback_base:
        lines.append(f"> 这条建议有用吗？[有用]({feedback_base}/feedback/{record_id}?vote=up)　"
                     f"[没用]({feedback_base}/feedback/{record_id}?vote=down)")
    lines.append(f"> 分析编号：{record_id}")
    return truncate("\n".join(lines))


def format_fallback(group: AlertGroup, ctx: dict, reason: str, record_id: str) -> str:
    """降级：大模型不可用时，照样推送告警和已经采集到的上下文，值班的人看这些也能先动起来。"""
    lines = _header(group) + ["", f"**AI 分析不可用**：{reason}，下面是自动采集的上下文。", ""]
    ann = group.annotations
    if ann.get("description"):
        lines += [f"**描述**：{ann['description']}", ""]
    for title, key in (("指标", "prometheus"), ("日志", "loki"), ("K8s", "kubernetes")):
        items = ctx.get(key) or []
        if items:
            lines.append(f"**{title}**")
            lines += [f"> {x}" for x in items[:6]]
    lines.append(f"> 分析编号：{record_id}")
    return truncate("\n".join(lines))


def dingtalk_signed_url(url: str, secret: str, now_ms: int | None = None) -> str:
    ts = now_ms if now_ms is not None else int(time.time() * 1000)
    digest = hmac.new(secret.encode(), f"{ts}\n{secret}".encode(), hashlib.sha256).digest()
    return f"{url}&timestamp={ts}&sign={urllib.parse.quote_plus(base64.b64encode(digest).decode())}"


class Notifier:
    def __init__(self, settings, http=None):
        import httpx

        self.s = settings
        self.http = http or httpx.Client(timeout=5.0)
        self.dry_run_messages: list[str] = []

    def send(self, title: str, markdown: str) -> list[str]:
        """返回发送结果列表，比如 ["wecom:ok", "dingtalk:error ..."]。一个都没配就进演练模式只打印。"""
        results = []
        targets = []
        if self.s.wecom_webhook:
            targets.append(("wecom", self.s.wecom_webhook, {"msgtype": "markdown", "markdown": {"content": markdown}}))
        if self.s.dingtalk_webhook:
            url = self.s.dingtalk_webhook
            if self.s.dingtalk_secret:
                url = dingtalk_signed_url(url, self.s.dingtalk_secret)
            targets.append(("dingtalk", url, {"msgtype": "markdown", "markdown": {"title": title, "text": markdown}}))
        if not targets:
            self.dry_run_messages.append(markdown)
            print(json.dumps({"event": "dry_run_notify", "title": title, "text": markdown}, ensure_ascii=False),
                  flush=True)
            return ["dry-run"]
        for name, url, body in targets:
            try:
                r = self.http.post(url, json=body)
                data = r.json() if r.content else {}
                ok = r.status_code == 200 and data.get("errcode", 0) == 0
                results.append(f"{name}:{'ok' if ok else 'error ' + r.text[:100]}")
            except Exception as e:  # noqa: BLE001
                results.append(f"{name}:error {type(e).__name__}")
        return results
