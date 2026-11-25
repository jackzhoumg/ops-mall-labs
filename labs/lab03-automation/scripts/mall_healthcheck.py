#!/usr/bin/env python3
"""mall-api 健康巡检：检查 /healthz、/readyz、/api/products，异常时推送企业微信 / 钉钉机器人。

只用 Python 标准库，Rocky Linux 9 自带的 python3 直接能跑，不用 pip 装依赖。

用法：
    export WECOM_WEBHOOK_URL='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx'
    # 或者钉钉（加签方式）：
    export DINGTALK_WEBHOOK_URL='https://oapi.dingtalk.com/robot/send?access_token=xxx'
    export DINGTALK_SECRET='SECxxx'
    python3 mall_healthcheck.py
    python3 mall_healthcheck.py --targets http://192.168.56.11:8080,http://192.168.56.12:8080 --dry-run

环境变量：
    MALL_TARGETS          逗号分隔的 mall-api 地址，默认两台 web 机器的 8080
    MALL_SLOW_MS          接口耗时超过多少毫秒算慢，默认 1000
    MALL_CHECK_STATE      上次检查结果存放位置，用来做“状态变化才通知”，默认 /tmp/mall_healthcheck.json
    WECOM_WEBHOOK_URL     企业微信群机器人地址
    DINGTALK_WEBHOOK_URL  钉钉群机器人地址
    DINGTALK_SECRET       钉钉机器人“加签”密钥，不用加签可以不设

退出码：0 全部正常；1 有异常；2 参数或配置错误
对应教程：Lab 03 Shell / Python 与 Ansible 自动化
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import logging
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field

DEFAULT_TARGETS = "http://192.168.56.11:8080,http://192.168.56.12:8080"
TIMEOUT_SECONDS = 3

log = logging.getLogger("mall_healthcheck")


@dataclass
class CheckResult:
    target: str
    ok: bool = True
    problems: list[str] = field(default_factory=list)
    details: dict[str, str] = field(default_factory=dict)

    def fail(self, msg: str) -> None:
        self.ok = False
        self.problems.append(msg)


# ---------------- 纯函数：不碰网络，方便写单元测试 ----------------


def parse_targets(raw: str) -> list[str]:
    """把 'a, b,,c/' 解析成 ['a', 'b', 'c']，去掉空项和末尾斜杠。"""
    return [t.strip().rstrip("/") for t in raw.split(",") if t.strip()]


def evaluate_readyz(status: int, body: str) -> list[str]:
    """根据 /readyz 的状态码和响应体，返回问题列表（空列表表示就绪）。

    mall-api 的 /readyz 返回 {"ready": bool, "checks": {"mysql": "ok", "redis": "错误信息"}}。
    """
    problems: list[str] = []
    try:
        data = json.loads(body)
    except (ValueError, TypeError):
        data = {}
    checks = data.get("checks", {}) if isinstance(data, dict) else {}
    for name, value in sorted(checks.items()):
        if value != "ok":
            problems.append(f"{name} 不可用: {value}")
    if status != 200 and not problems:
        problems.append(f"/readyz 返回 HTTP {status}")
    return problems


def evaluate_products(status: int, body: str) -> list[str]:
    """商品列表必须是 200 且非空数组。"""
    if status != 200:
        return [f"/api/products 返回 HTTP {status}"]
    try:
        data = json.loads(body)
    except ValueError:
        return ["/api/products 返回的不是 JSON"]
    if not isinstance(data, list) or not data:
        return ["/api/products 返回空列表，检查数据库里有没有商品数据"]
    return []


def should_notify(prev_ok: bool | None, curr_ok: bool) -> bool:
    """只在状态变化时通知：正常->异常发告警，异常->正常发恢复。

    prev_ok 为 None 表示第一次检查：只有异常才通知。
    持续异常不重复发，避免群里被刷屏（重复提醒交给 Lab 09 的 Alertmanager 做）。
    """
    if prev_ok is None:
        return not curr_ok
    return prev_ok != curr_ok


def format_message(result: CheckResult, hostname: str) -> str:
    """生成 Markdown 告警文本，企业微信和钉钉都能显示。"""
    title = "恢复" if result.ok else "告警"
    lines = [f"### [ops-mall {title}] mall-api 健康巡检", f"- 实例：{result.target}"]
    for k, v in result.details.items():
        lines.append(f"- {k}：{v}")
    for p in result.problems:
        lines.append(f"- 问题：{p}")
    lines.append(f"- 巡检机器：{hostname}")
    lines.append(f"- 时间：{time.strftime('%Y-%m-%d %H:%M:%S')}")
    return "\n".join(lines)


def build_wecom_payload(text: str) -> dict:
    """企业微信群机器人 markdown 消息格式。"""
    return {"msgtype": "markdown", "markdown": {"content": text}}


def build_dingtalk_payload(text: str, title: str = "ops-mall 巡检") -> dict:
    """钉钉群机器人 markdown 消息格式。"""
    return {"msgtype": "markdown", "markdown": {"title": title, "text": text}}


def dingtalk_sign(secret: str, timestamp_ms: int) -> str:
    """钉钉加签：HmacSHA256(timestamp + "\\n" + secret)，再 Base64、URL 编码。"""
    string_to_sign = f"{timestamp_ms}\n{secret}".encode()
    digest = hmac.new(secret.encode(), string_to_sign, hashlib.sha256).digest()
    return urllib.parse.quote_plus(base64.b64encode(digest).decode())


def dingtalk_signed_url(url: str, secret: str, timestamp_ms: int) -> str:
    sign = dingtalk_sign(secret, timestamp_ms)
    sep = "&" if "?" in url else "?"
    return f"{url}{sep}timestamp={timestamp_ms}&sign={sign}"


# ---------------- 有副作用的函数：网络、文件 ----------------


def http_get(url: str, insecure: bool = False) -> tuple[int, str, float]:
    """返回 (状态码, 响应体, 耗时毫秒)。连不上时状态码为 0，body 是错误原因。"""
    ctx = ssl._create_unverified_context() if insecure else None  # 自签证书时用 --insecure
    req = urllib.request.Request(url, headers={"User-Agent": "mall-healthcheck/1.0"})
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS, context=ctx) as resp:
            body = resp.read().decode("utf-8", "replace")
            return resp.status, body, (time.monotonic() - start) * 1000
    except urllib.error.HTTPError as e:
        # 4xx / 5xx 也有响应体，比如 /readyz 的 503 里写着哪个依赖挂了
        body = e.read().decode("utf-8", "replace")
        return e.code, body, (time.monotonic() - start) * 1000
    except (urllib.error.URLError, socket.timeout, ConnectionError) as e:
        reason = getattr(e, "reason", e)
        return 0, str(reason), (time.monotonic() - start) * 1000


def check_target(target: str, slow_ms: float, insecure: bool) -> CheckResult:
    result = CheckResult(target=target)

    status, body, _ = http_get(f"{target}/healthz", insecure)
    if status != 200:
        result.fail(f"/healthz 失败（HTTP {status}）：{body[:200]}，进程可能没在运行")
        return result  # 进程都不在，后面不用查了

    status, body, _ = http_get(f"{target}/readyz", insecure)
    for p in evaluate_readyz(status, body):
        result.fail(p)

    status, body, cost = http_get(f"{target}/api/products", insecure)
    result.details["商品接口耗时"] = f"{cost:.0f}ms"
    for p in evaluate_products(status, body):
        result.fail(p)
    if status == 200 and cost > slow_ms:
        result.fail(f"/api/products 耗时 {cost:.0f}ms，超过 {slow_ms:.0f}ms")

    status, body, _ = http_get(f"{target}/api/version", insecure)
    if status == 200:
        try:
            v = json.loads(body)
            result.details["版本"] = f"{v.get('version')}（{v.get('hostname')}）"
        except ValueError:
            pass
    return result


def load_state(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(path: str, state: dict) -> None:
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f)
    os.replace(tmp, path)  # 原子替换，脚本中途被杀也不会留下半截文件


def post_json(url: str, payload: dict) -> None:
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        body = json.loads(resp.read().decode("utf-8", "replace") or "{}")
    # 两家机器人都是 HTTP 200 + errcode 表示结果，errcode != 0 就是失败（比如关键词不匹配、签名错）
    if body.get("errcode", 0) != 0:
        raise RuntimeError(f"机器人返回错误：{body}")


def notify(text: str, dry_run: bool) -> None:
    wecom = os.environ.get("WECOM_WEBHOOK_URL", "")
    ding = os.environ.get("DINGTALK_WEBHOOK_URL", "")
    if dry_run or not (wecom or ding):
        log.info("未发送（dry-run 或没配 Webhook），消息内容：\n%s", text)
        return
    if wecom:
        try:
            post_json(wecom, build_wecom_payload(text))
            log.info("已推送企业微信")
        except Exception as e:  # 推送失败不能让巡检脚本崩掉
            log.error("推送企业微信失败：%s", e)
    if ding:
        secret = os.environ.get("DINGTALK_SECRET", "")
        url = dingtalk_signed_url(ding, secret, int(time.time() * 1000)) if secret else ding
        try:
            post_json(url, build_dingtalk_payload(text))
            log.info("已推送钉钉")
        except Exception as e:
            log.error("推送钉钉失败：%s", e)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="mall-api 健康巡检")
    parser.add_argument("--targets", default=os.environ.get("MALL_TARGETS", DEFAULT_TARGETS))
    parser.add_argument("--slow-ms", type=float, default=float(os.environ.get("MALL_SLOW_MS", "1000")))
    parser.add_argument("--state", default=os.environ.get("MALL_CHECK_STATE", "/tmp/mall_healthcheck.json"))
    parser.add_argument("--insecure", action="store_true", help="不校验 HTTPS 证书（实验环境自签证书）")
    parser.add_argument("--dry-run", action="store_true", help="只打印消息，不推送")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

    targets = parse_targets(args.targets)
    if not targets:
        log.error("没有可检查的目标，设置 MALL_TARGETS 或 --targets")
        return 2

    state = load_state(args.state)
    hostname = socket.gethostname()
    all_ok = True
    for target in targets:
        result = check_target(target, args.slow_ms, args.insecure)
        all_ok = all_ok and result.ok
        if result.ok:
            log.info("%s 正常 %s", target, result.details)
        else:
            log.warning("%s 异常：%s", target, "; ".join(result.problems))
        if should_notify(state.get(target), result.ok):
            notify(format_message(result, hostname), args.dry_run)
        state[target] = result.ok

    if not args.dry_run:  # dry-run 不记状态，免得下次真跑时漏发告警
        save_state(args.state, state)
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
