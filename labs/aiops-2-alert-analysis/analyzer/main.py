"""alert-analyzer：接收 Alertmanager webhook，采集上下文，调大模型分析，推送到群。

接口：
  POST /alertmanager            Alertmanager webhook（立即返回 200，分析在后台做）
  GET  /feedback/{id}?vote=up   群消息里的"有用 / 没用"链接
  GET  /stats                   效果统计（JSON）
  GET  /metrics                 Prometheus 指标
  GET  /healthz                 存活检查
"""
from __future__ import annotations

import json
import time
from datetime import datetime, timezone

from fastapi import BackgroundTasks, FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, PlainTextResponse

from . import notify, prompt
from .aggregator import AlertGroup, Cooldown, group_alerts, group_key
from .config import Settings
from .store import Store


def log(**fields):
    fields["ts"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    print(json.dumps(fields, ensure_ascii=False), flush=True)


class Counters:
    """自己数几个计数器，不引入 prometheus_client。"""

    def __init__(self):
        self.received = 0
        self.analyzed = {"ok": 0, "fallback": 0}
        self.suppressed = 0
        self.skipped = 0
        self.llm_seconds_sum = 0.0
        self.llm_calls = 0

    def render(self) -> str:
        lines = [
            "# TYPE alert_analyzer_alert_groups_received_total counter",
            f"alert_analyzer_alert_groups_received_total {self.received}",
            "# TYPE alert_analyzer_analyses_total counter",
            *[f'alert_analyzer_analyses_total{{result="{k}"}} {v}' for k, v in self.analyzed.items()],
            "# TYPE alert_analyzer_suppressed_total counter",
            f"alert_analyzer_suppressed_total {self.suppressed}",
            "# TYPE alert_analyzer_skipped_total counter",
            f"alert_analyzer_skipped_total {self.skipped}",
            "# TYPE alert_analyzer_llm_seconds summary",
            f"alert_analyzer_llm_seconds_sum {self.llm_seconds_sum:.3f}",
            f"alert_analyzer_llm_seconds_count {self.llm_calls}",
        ]
        return "\n".join(lines) + "\n"


class Pipeline:
    """一个告警组的处理流程。collector / llm / notifier / store 都可以注入假的，方便测试。"""

    def __init__(self, settings: Settings, collector, llm, notifier, store: Store, counters: Counters):
        self.s, self.collector, self.llm, self.notifier, self.store, self.c = (
            settings, collector, llm, notifier, store, counters)

    def run(self, group: AlertGroup, suppressed: int = 0):
        rid = self.store.new_id()
        try:
            ctx = self.collector.collect(group)
        except Exception as e:  # noqa: BLE001 采集整体出错也要推送
            ctx = {"prometheus": [f"采集出错：{type(e).__name__}"], "loki": [], "kubernetes": []}

        analysis, reason, llm_ms = None, "", 0
        if self.llm is None:
            reason = "未配置大模型"
        else:
            t0 = time.monotonic()
            try:
                raw = self.llm.chat(prompt.build_messages(group, ctx, self.s.max_context_chars))
                analysis = prompt.parse_output(raw)
                if analysis is None:
                    reason = "大模型输出不是合法 JSON"
                    log(event="llm_bad_output", alertname=group.alertname, raw=raw[:500])
            except Exception as e:  # noqa: BLE001 超时、限流、服务挂了
                reason = f"大模型调用失败（{type(e).__name__}）"
                log(event="llm_error", alertname=group.alertname, error=str(e)[:200])
            llm_ms = int((time.monotonic() - t0) * 1000)
            self.c.llm_calls += 1
            self.c.llm_seconds_sum += llm_ms / 1000

        title = f"{group.alertname} {group.namespace}"
        if analysis:
            text = notify.format_analysis(group, analysis, rid, self.s.feedback_base_url, suppressed)
            result = "ok"
        else:
            text = notify.format_fallback(group, ctx, reason, rid)
            result = "fallback"
        sent = self.notifier.send(title, text)
        self.store.save(rid, group.alertname, group.namespace, group.severity, result, reason, llm_ms, analysis)
        self.c.analyzed[result] += 1
        log(event="analyzed", id=rid, alertname=group.alertname, namespace=group.namespace, result=result,
            reason=reason, llm_ms=llm_ms, sent=sent)
        return rid, result


def create_app(settings: Settings | None = None, collector=None, llm=None, notifier=None, store=None,
               cooldown: Cooldown | None = None) -> FastAPI:
    s = settings or Settings.from_env()
    if collector is None:
        from .context import Collector

        collector = Collector(s)
    if llm is None and s.llm_enabled:
        from .llm import ChatClient

        llm = ChatClient(s.llm_base_url, s.llm_api_key, s.llm_model, s.llm_timeout, s.llm_json_mode)
    notifier = notifier or notify.Notifier(s)
    store = store or Store(s.db_path)
    cooldown = cooldown or Cooldown(s.cooldown_seconds)
    counters = Counters()
    pipeline = Pipeline(s, collector, llm, notifier, store, counters)

    app = FastAPI(title="alert-analyzer", docs_url=None, redoc_url=None)
    app.state.pipeline, app.state.cooldown, app.state.counters = pipeline, cooldown, counters

    @app.get("/healthz")
    def healthz():
        return {"status": "ok", "llm": "enabled" if llm else "disabled"}

    @app.post("/alertmanager")
    async def alertmanager(request: Request, background: BackgroundTasks):
        try:
            payload = await request.json()
        except Exception:  # noqa: BLE001
            raise HTTPException(400, "invalid json")
        # 恢复的告警：清掉冷却，下次再触发重新分析
        for a in payload.get("alerts", []) or []:
            if a.get("status") == "resolved":
                cooldown.reset(group_key(a.get("labels", {}) or {}))
        accepted = []
        for g in group_alerts(payload, "firing"):
            counters.received += 1
            if g.severity not in s.analyze_severities:
                counters.skipped += 1
                continue
            if not cooldown.allow(g.key):
                counters.suppressed += 1
                log(event="suppressed", key=g.key, times=cooldown.suppressed.get(g.key, 0))
                continue
            suppressed_before = cooldown.suppressed.pop(g.key, 0)
            background.add_task(pipeline.run, g, suppressed_before)
            accepted.append(g.key)
        cooldown.gc()
        # 立刻返回：Alertmanager 的 webhook 请求有超时，分析要十几秒，不能让它等
        return {"accepted": accepted}

    @app.get("/feedback/{rid}", response_class=HTMLResponse)
    def feedback(rid: str, vote: str, note: str = ""):
        if vote not in ("up", "down"):
            raise HTTPException(400, "vote must be up or down")
        if not store.exists(rid):
            raise HTTPException(404, "analysis not found")
        store.add_feedback(rid, vote, note)
        log(event="feedback", id=rid, vote=vote)
        return "<p>已记录，谢谢反馈。可以关闭这个页面。</p>"

    @app.get("/stats")
    def stats():
        return store.stats()

    @app.get("/metrics", response_class=PlainTextResponse)
    def metrics():
        return counters.render()

    return app


# 启动：uvicorn --factory analyzer.main:create_app --host 0.0.0.0 --port 8080
# 用工厂函数而不是模块级 app：import 本模块（比如跑测试）时不会去连真实服务
