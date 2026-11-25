"""收集告警上下文：Prometheus 指标（近 15 分钟）、Loki 错误日志、K8s Pod 状态和事件。

原则：
- 每个数据源单独设超时，任何一个失败都不影响其他的，失败原因写进上下文（让模型知道"没拿到"而不是"没有"）；
- 原始数据先在本地压缩成摘要（最小 / 最大 / 最新值、日志按消息去重计数），再交给大模型。
  直接把 900 个数据点或 500 行日志塞进去，又贵又容易把模型带偏。
"""
from __future__ import annotations

import json
import re
import time
import urllib.parse
from collections import Counter
from datetime import datetime, timezone

from .aggregator import AlertGroup
from .redact import redact

# 告警名 → 额外要看的 PromQL。${namespace} 会替换成告警的 namespace。
# 告警自己的表达式会从 generatorURL 里取出来，不用写在这里。
EXTRA_QUERIES: dict[str, list[tuple[str, str]]] = {
    "MallApiHighErrorRate": [
        ("按路由的 5xx 速率（次/秒）",
         'sum by (route, status) (rate(mall_http_requests_total{namespace="${namespace}", status=~"5.."}[5m]))'),
        ("总请求速率（次/秒）",
         'sum(rate(mall_http_requests_total{namespace="${namespace}", route!~"GET /(healthz|readyz|metrics)"}[5m]))'),
        ("运行中的版本", 'count by (version) (mall_build_info{namespace="${namespace}"})'),
    ],
    "MallApiHighLatency": [
        ("按路由的 P99 延迟（秒）",
         'histogram_quantile(0.99, sum by (route, le) '
         '(rate(mall_http_request_duration_seconds_bucket{namespace="${namespace}"}[5m])))'),
        ("处理中的请求数", 'sum(mall_http_inflight_requests{namespace="${namespace}"})'),
        ("CPU 使用（核）",
         'sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="${namespace}", container="mall-api"}[5m]))'),
    ],
    "MallPodOOMKilled": [
        ("内存工作集（字节）",
         'max by (pod) (container_memory_working_set_bytes{namespace="${namespace}", container="mall-api"})'),
    ],
    "MallPodCrashLooping": [
        ("15 分钟重启次数",
         'sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="${namespace}"}[15m]))'),
    ],
    "MallPodRestartingFrequently": [
        ("15 分钟重启次数",
         'sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="${namespace}"}[15m]))'),
        ("内存工作集（字节）",
         'max by (pod) (container_memory_working_set_bytes{namespace="${namespace}", container="mall-api"})'),
    ],
}


def fill(template: str, group: AlertGroup) -> str:
    return template.replace("${namespace}", group.namespace or "mall")


def expr_from_generator_url(url: str) -> str:
    """Prometheus 告警的 generatorURL 形如 http://.../graph?g0.expr=<URL 编码的表达式>&g0.tab=1。"""
    if not url:
        return ""
    qs = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
    return (qs.get("g0.expr") or [""])[0]


def queries_for(group: AlertGroup) -> list[tuple[str, str]]:
    out = []
    expr = expr_from_generator_url(group.alerts[0].get("generatorURL", "")) if group.alerts else ""
    if expr:
        out.append(("告警表达式本身", expr))
    out += [(name, fill(q, group)) for name, q in EXTRA_QUERIES.get(group.alertname, [])]
    return out


# ---------------------------------------------------------------- 摘要（纯函数，方便测试）


def _fmt(v: float) -> str:
    if v != v:  # NaN
        return "NaN"
    if abs(v) >= 1e6:
        return f"{v:.3e}"
    return f"{v:.4g}"


def summarize_matrix(result: list[dict], max_series: int = 8) -> list[str]:
    """query_range 的 matrix 结果 → 每条序列一行：标签 + 最小 / 最大 / 最新值 + 趋势。"""
    lines = []
    series = []
    for s in result:
        vals = []
        for _, v in s.get("values", []):
            try:
                vals.append(float(v))
            except (TypeError, ValueError):
                continue
        if vals:
            series.append((s.get("metric", {}), vals))
    # 最新值大的排前面，最"热"的序列先给模型看
    series.sort(key=lambda x: x[1][-1] if x[1][-1] == x[1][-1] else float("-inf"), reverse=True)
    for metric, vals in series[:max_series]:
        labels = ",".join(f'{k}="{v}"' for k, v in sorted(metric.items()) if k != "__name__") or "(无标签)"
        first, last = vals[0], vals[-1]
        if last > first * 1.2 + 1e-9:
            trend = "上升"
        elif last < first * 0.8 - 1e-9:
            trend = "下降"
        else:
            trend = "平稳"
        lines.append(f"{labels} 最小={_fmt(min(vals))} 最大={_fmt(max(vals))} 最新={_fmt(last)} 趋势={trend}")
    if len(series) > max_series:
        lines.append(f"...另有 {len(series) - max_series} 条序列省略")
    return lines


def summarize_logs(streams: list[dict], max_kinds: int = 10) -> list[str]:
    """Loki streams → 按 (级别, msg, route, status) 去重计数，附一条样例。mall-api 日志是 slog JSON。"""
    counter: Counter = Counter()
    sample: dict = {}
    for st in streams:
        for _, line in st.get("values", []):
            try:
                obj = json.loads(line)
            except (json.JSONDecodeError, TypeError):
                obj = {"msg": str(line)[:200]}
            key = (obj.get("level", ""), obj.get("msg", ""), obj.get("route", ""), str(obj.get("status", "")),
                   str(obj.get("err", ""))[:120])
            counter[key] += 1
            sample.setdefault(key, obj)
    lines = []
    for key, n in counter.most_common(max_kinds):
        level, msg, route, status, err = key
        parts = [f"{n} 次", level, f"msg={msg}"]
        if route:
            parts.append(f"route={route}")
        if status:
            parts.append(f"status={status}")
        if err:
            parts.append(f"err={err}")
        rid = sample[key].get("request_id")
        if rid:
            parts.append(f"样例request_id={rid}")
        lines.append(" ".join(p for p in parts if p))
    return [redact(x) for x in lines]


def summarize_pods(pod_list: dict) -> list[str]:
    lines = []
    for p in pod_list.get("items", []):
        name = p.get("metadata", {}).get("name", "")
        status = p.get("status", {})
        for cs in status.get("containerStatuses", []) or []:
            state = next(iter(cs.get("state", {}) or {}), "unknown")
            waiting = (cs.get("state", {}).get("waiting") or {}).get("reason", "")
            last = (cs.get("lastState", {}).get("terminated") or {})
            line = (f"{name} phase={status.get('phase')} ready={cs.get('ready')} "
                    f"restarts={cs.get('restartCount', 0)} state={state}{'(' + waiting + ')' if waiting else ''}")
            if last:
                line += f" 上次退出={last.get('reason')} exitCode={last.get('exitCode')} 时间={last.get('finishedAt')}"
            lines.append(line)
    return lines


def _parse_ts(s: str) -> float:
    if not s:
        return 0.0
    try:
        return datetime.fromisoformat(re.sub(r"\.\d+", "", s).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


def summarize_events(event_list: dict, since_ts: float, name_prefix: str = "", max_items: int = 15) -> list[str]:
    """只要 Warning 事件、在时间窗口内、对象名以前缀开头（如 mall-api），按最后发生时间倒序。"""
    rows = []
    for e in event_list.get("items", []):
        if e.get("type") != "Warning":
            continue
        obj = e.get("involvedObject", {}) or {}
        if name_prefix and not obj.get("name", "").startswith(name_prefix):
            continue
        ts = _parse_ts(e.get("lastTimestamp") or e.get("eventTime") or e.get("metadata", {}).get("creationTimestamp", ""))
        if ts and ts < since_ts:
            continue
        rows.append((ts, f"{obj.get('kind')}/{obj.get('name')} {e.get('reason')} x{e.get('count') or 1}: "
                         f"{(e.get('message') or '')[:200]}"))
    rows.sort(reverse=True)
    return [r for _, r in rows[:max_items]]


# ---------------------------------------------------------------- 采集（联网）


class Collector:
    def __init__(self, settings, http=None, k8s=None):
        import httpx  # 延迟导入，纯函数测试不需要

        self.s = settings
        self.http = http or httpx.Client(timeout=settings.source_timeout)
        self.k8s_error = ""
        if k8s is not None or not settings.k8s_enabled:
            self.k8s = k8s
        else:
            try:
                self.k8s = K8sClient(settings.source_timeout)
            except Exception as e:  # noqa: BLE001 本地调试不在集群里，K8s 采集自动关闭
                self.k8s, self.k8s_error = None, f"{type(e).__name__}: {e}"

    def prometheus(self, group: AlertGroup, now: float) -> list[str]:
        out = []
        start = now - self.s.lookback_minutes * 60
        for name, q in queries_for(group):
            try:
                r = self.http.get(f"{self.s.prom_url}/api/v1/query_range",
                                  params={"query": q, "start": start, "end": now, "step": "60"})
                r.raise_for_status()
                data = r.json().get("data", {})
                lines = summarize_matrix(data.get("result", []))
                out.append(f"[{name}] {q}")
                out += [f"  {x}" for x in (lines or ["（无数据）"])]
            except Exception as e:  # noqa: BLE001
                out.append(f"[{name}] 查询失败：{type(e).__name__}: {str(e)[:120]}")
        return out

    def loki(self, group: AlertGroup, now: float) -> list[str]:
        selector = self.s.loki_selector.replace("${namespace}", group.namespace or "mall")
        query = f'{selector} | json | level=~"ERROR|WARN"'
        headers = {"X-Scope-OrgID": self.s.loki_tenant} if self.s.loki_tenant else {}
        try:
            r = self.http.get(f"{self.s.loki_url}/loki/api/v1/query_range", headers=headers, params={
                "query": query, "start": int((now - self.s.lookback_minutes * 60) * 1e9),
                "end": int(now * 1e9), "limit": 500, "direction": "backward"})
            r.raise_for_status()
            lines = summarize_logs(r.json().get("data", {}).get("result", []))
            return [f"LogQL: {query}"] + (lines or ["（时间窗口内没有 ERROR / WARN 日志）"])
        except Exception as e:  # noqa: BLE001
            return [f"Loki 查询失败：{type(e).__name__}: {str(e)[:120]}"]

    def kubernetes(self, group: AlertGroup, now: float) -> list[str]:
        if not self.k8s:
            return [f"（K8s 采集不可用：{self.k8s_error}）" if self.k8s_error else "（未启用 K8s 采集）"]
        ns = group.namespace or "mall"
        out = []
        try:
            pods = self.k8s.get(f"/api/v1/namespaces/{ns}/pods",
                                {"labelSelector": self.s.k8s_label_selector})
            out += ["Pod 状态："] + (summarize_pods(pods) or ["  （没有匹配的 Pod）"])
        except Exception as e:  # noqa: BLE001
            out.append(f"Pod 查询失败：{type(e).__name__}: {str(e)[:120]}")
        try:
            events = self.k8s.get(f"/api/v1/namespaces/{ns}/events", {"limit": "200"})
            ev = summarize_events(events, now - self.s.lookback_minutes * 60, name_prefix="mall-api")
            out += ["Warning 事件："] + (ev or ["  （时间窗口内没有 Warning 事件）"])
        except Exception as e:  # noqa: BLE001
            out.append(f"事件查询失败：{type(e).__name__}: {str(e)[:120]}")
        return out

    def collect(self, group: AlertGroup, now: float | None = None) -> dict:
        now = now or time.time()
        return {
            "prometheus": self.prometheus(group, now),
            "loki": self.loki(group, now),
            "kubernetes": self.kubernetes(group, now),
        }


class K8sClient:
    """最小的 K8s API 客户端：用 Pod 里挂载的 ServiceAccount 令牌，只读两个接口，不引入 kubernetes 库。"""

    SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"

    def __init__(self, timeout: float):
        import os
        import ssl

        import httpx

        host = os.environ.get("KUBERNETES_SERVICE_HOST")
        port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
        if not host:
            raise RuntimeError("不在 K8s 里运行，设置 K8S_ENABLED=false")
        self.base = f"https://{host}:{port}"
        with open(f"{self.SA_DIR}/token", encoding="utf-8") as f:
            token = f.read().strip()
        self.http = httpx.Client(timeout=timeout, verify=ssl.create_default_context(cafile=f"{self.SA_DIR}/ca.crt"),
                                 headers={"Authorization": f"Bearer {token}"})

    def get(self, path: str, params: dict) -> dict:
        r = self.http.get(self.base + path, params=params)
        r.raise_for_status()
        return r.json()
