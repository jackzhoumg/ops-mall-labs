#!/usr/bin/env python3
"""alert-bridge：把 Alertmanager 的 webhook 消息转成企业微信 / 钉钉群机器人消息。

只用 Python 标准库，一个文件，方便学员读懂。

接口：
  POST /wecom/<name>     发到企业微信群机器人，地址取环境变量 WECOM_WEBHOOK_<NAME>
  POST /dingtalk/<name>  发到钉钉群机器人，地址取 DINGTALK_WEBHOOK_<NAME>，
                         开了"加签"的再配 DINGTALK_SECRET_<NAME>
  GET  /healthz          存活检查

<name> 只允许小写字母、数字、短横线，环境变量名里转成大写、短横线换成下划线。
对应的环境变量没配置时进入演练模式：消息只打印到标准输出，不往外发，方便没有机器人也能做实验。

发送失败返回 502，Alertmanager 会按自己的重试策略再发。
"""

import base64
import hashlib
import hmac
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))
TZ = timezone(timedelta(hours=8))  # 北京时间
SEVERITY_TEXT = {"critical": "P1 紧急", "warning": "P2 重要", "info": "P3 提示"}
# 企业微信 markdown 内容最长 4096 字节；钉钉限制更宽，统一按 4000 字节截断，留点余量
MAX_BYTES = int(os.environ.get("MAX_BYTES", "4000"))
PATH_RE = re.compile(r"^/(wecom|dingtalk)/([a-z0-9-]{1,32})$")


def log(**fields):
    fields["ts"] = datetime.now(TZ).isoformat(timespec="seconds")
    print(json.dumps(fields, ensure_ascii=False), flush=True)


def fmt_time(value):
    """Alertmanager 给的是 RFC3339 UTC 时间，转成北京时间显示。"""
    if not value or value.startswith("0001-"):
        return "-"
    try:
        # 去掉小数秒，兼容 Python 3.10 之前不认 "Z" 和纳秒的情况
        base = re.sub(r"\.\d+", "", value).replace("Z", "+00:00")
        return datetime.fromisoformat(base).astimezone(TZ).strftime("%m-%d %H:%M:%S")
    except ValueError:
        return value


def truncate(text, limit=MAX_BYTES):
    raw = text.encode("utf-8")
    if len(raw) <= limit:
        return text
    cut = raw[: limit - 40].decode("utf-8", errors="ignore")
    return cut + "\n\n……内容过长已截断，请到 Alertmanager 查看完整告警"


def render(payload):
    """把一组告警渲染成 markdown，返回 (标题, 正文)。"""
    status = payload.get("status", "firing")
    common = payload.get("commonLabels", {})
    alerts = payload.get("alerts", [])
    firing = [a for a in alerts if a.get("status") == "firing"]
    resolved = [a for a in alerts if a.get("status") == "resolved"]
    name = common.get("alertname", "多个告警")
    sev = SEVERITY_TEXT.get(common.get("severity", ""), common.get("severity", "未分级"))

    if status == "firing":
        title = f"【告警 {sev}】{name}（{len(firing)} 条）"
    else:
        title = f"【已恢复】{name}（{len(resolved)} 条）"

    lines = [f"### {title}"]
    for a in firing + resolved:
        labels = a.get("labels", {})
        ann = a.get("annotations", {})
        where = labels.get("hostname") or labels.get("pod") or labels.get("namespace") or labels.get("instance", "")
        state = "触发" if a.get("status") == "firing" else "恢复"
        lines.append("")
        lines.append(f"**[{state}] {ann.get('summary', labels.get('alertname', ''))}**")
        if ann.get("description"):
            lines.append(f"> {ann['description']}")
        if where:
            lines.append(f"> 对象：{where}")
        lines.append(f"> 开始：{fmt_time(a.get('startsAt'))}")
        if a.get("status") == "resolved":
            lines.append(f"> 恢复：{fmt_time(a.get('endsAt'))}")
    if payload.get("truncatedAlerts"):
        lines.append(f"\n还有 {payload['truncatedAlerts']} 条告警未显示（max_alerts 限制）")
    return title, truncate("\n".join(lines))


def wecom_body(title, text):
    return {"msgtype": "markdown", "markdown": {"content": text}}


def dingtalk_body(title, text):
    return {"msgtype": "markdown", "markdown": {"title": title, "text": text}}


def dingtalk_sign(url, secret):
    """钉钉"加签"：timestamp + "\\n" + secret 做 HmacSHA256，再 base64、urlencode，拼到 URL 上。"""
    ts = str(round(time.time() * 1000))
    string_to_sign = f"{ts}\n{secret}".encode("utf-8")
    digest = hmac.new(secret.encode("utf-8"), string_to_sign, hashlib.sha256).digest()
    sign = urllib.parse.quote_plus(base64.b64encode(digest))
    sep = "&" if "?" in url else "?"
    return f"{url}{sep}timestamp={ts}&sign={sign}"


def post_json(url, body):
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        result = json.loads(resp.read().decode("utf-8") or "{}")
    # 两家机器人接口出错时 HTTP 状态码仍是 200，要看返回体里的 errcode
    if result.get("errcode", 0) != 0:
        raise RuntimeError(f"robot api error: {result}")
    return result


def env_key(name):
    return name.upper().replace("-", "_")


def deliver(channel, name, payload):
    title, text = render(payload)
    key = env_key(name)
    if channel == "wecom":
        url = os.environ.get(f"WECOM_WEBHOOK_{key}", "")
        body = wecom_body(title, text)
    else:
        url = os.environ.get(f"DINGTALK_WEBHOOK_{key}", "")
        secret = os.environ.get(f"DINGTALK_SECRET_{key}", "")
        if url and secret:
            url = dingtalk_sign(url, secret)
        body = dingtalk_body(title, text)
    if not url:
        log(event="dry_run", channel=channel, receiver=name, title=title, text=text)
        return
    post_json(url, body)
    log(event="sent", channel=channel, receiver=name, title=title)


class Handler(BaseHTTPRequestHandler):
    server_version = "alert-bridge/1.0"

    def _reply(self, code, msg):
        body = json.dumps({"message": msg}).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._reply(200, "ok")
        else:
            self._reply(404, "not found")

    def do_POST(self):
        m = PATH_RE.match(self.path)
        if not m:
            self._reply(404, "use /wecom/<name> or /dingtalk/<name>")
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > 1 << 20:
            self._reply(400, "empty or too large body")
            return
        try:
            payload = json.loads(self.rfile.read(length))
        except ValueError:
            self._reply(400, "invalid json")
            return
        try:
            deliver(m.group(1), m.group(2), payload)
        except Exception as exc:  # noqa: BLE001  发送失败统一回 502，让 Alertmanager 重试
            log(event="send_failed", channel=m.group(1), receiver=m.group(2), error=str(exc))
            self._reply(502, "send failed")
            return
        self._reply(200, "ok")

    def log_message(self, fmt, *args):
        pass  # 默认的访问日志太啰嗦，业务日志已经够用


def main():
    log(event="starting", port=LISTEN_PORT)
    srv = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
