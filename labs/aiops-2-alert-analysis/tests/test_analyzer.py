"""单元测试：不联网，Prometheus / Loki / K8s / 大模型 / 群机器人全部用假的。

运行：cd labs/aiops-2-alert-analysis && python -m pytest -q
"""
import json
import sys
from pathlib import Path

import httpx
import pytest

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))

from analyzer import context, notify, prompt  # noqa: E402
from analyzer.aggregator import Cooldown, group_alerts  # noqa: E402
from analyzer.config import Settings  # noqa: E402
from analyzer.llm import ChatClient, LLMError  # noqa: E402
from analyzer.main import create_app  # noqa: E402
from analyzer.store import Store  # noqa: E402

PAYLOAD = json.loads((HERE / "scripts" / "test-payload.json").read_text(encoding="utf-8"))

GOOD_OUTPUT = json.dumps({
    "summary": "mall-api 5xx 主要来自 /api/debug/error",
    "possible_causes": [{"cause": "有人在调用故障演练接口", "evidence": "route=GET /api/debug/error 5xx 1.2/s",
                         "confidence": "high"}],
    "steps": ["确认是否在做演练", "检查 MALL_DEBUG 配置"],
    "commands": [
        {"cmd": "kubectl -n mall logs deploy/mall-api --tail=50", "where": "k8s-master", "risk": "read-only"},
        {"cmd": "kubectl -n mall set env deploy/mall-api MALL_DEBUG=false", "where": "k8s-master",
         "risk": "read-only"},
        {"cmd": "kubectl delete ns mall", "where": "k8s-master", "risk": "change"},
    ],
    "need_human": False,
}, ensure_ascii=False)


class FakeCollector:
    def __init__(self):
        self.calls = 0

    def collect(self, group, now=None):
        self.calls += 1
        return {"prometheus": ['[按路由的 5xx 速率] route="GET /api/debug/error" 最新=1.2'],
                "loki": ["30 次 ERROR msg=debug error triggered"],
                "kubernetes": ["mall-api-abc phase=Running ready=True restarts=0"]}


class FakeLLM:
    def __init__(self, reply=GOOD_OUTPUT, exc=None):
        self.reply, self.exc, self.calls = reply, exc, []

    def chat(self, messages):
        self.calls.append(messages)
        if self.exc:
            raise self.exc
        return self.reply


class FakeNotifier:
    def __init__(self):
        self.sent = []

    def send(self, title, text):
        self.sent.append((title, text))
        return ["fake:ok"]


def make_client(tmp_path, llm=None, **settings_kw):
    from fastapi.testclient import TestClient

    s = Settings.from_env({})
    s.db_path = str(tmp_path / "a.db")
    s.feedback_base_url = "http://alert-analyzer.lab.local"
    for k, v in settings_kw.items():
        setattr(s, k, v)
    col, nt, st = FakeCollector(), FakeNotifier(), Store(s.db_path)
    app = create_app(s, collector=col, llm=llm, notifier=nt, store=st)
    return TestClient(app), col, nt, st


# ---------------------------------------------------------------- 聚合与冷却


def test_group_alerts_groups_by_name_namespace_severity():
    groups = group_alerts(PAYLOAD)
    assert len(groups) == 1
    g = groups[0]
    assert (g.alertname, g.namespace, g.severity) == ("MallApiHighErrorRate", "mall", "warning")
    assert len(g.alerts) == 2  # 两个 firing 实例合并，resolved 的不算


def test_group_alerts_resolved_only():
    assert [g.alertname for g in group_alerts(PAYLOAD, "resolved")] == ["MallPodRestartingFrequently"]


def test_cooldown():
    t = [1000.0]
    cd = Cooldown(600, clock=lambda: t[0])
    assert cd.allow("k")
    t[0] += 100
    assert not cd.allow("k")
    assert cd.suppressed["k"] == 1
    t[0] += 600
    assert cd.allow("k")
    cd.reset("k")
    assert cd.allow("k")


# ---------------------------------------------------------------- 上下文摘要


def test_expr_from_generator_url():
    url = PAYLOAD["alerts"][0]["generatorURL"]
    assert context.expr_from_generator_url(url).startswith("namespace_job:mall_http_error_ratio:rate5m > 0.01")
    assert context.expr_from_generator_url("") == ""


def test_queries_for_known_alert_fills_namespace():
    g = group_alerts(PAYLOAD)[0]
    qs = context.queries_for(g)
    assert qs[0][0] == "告警表达式本身"
    assert any('namespace="mall"' in q for _, q in qs[1:])
    assert all("${namespace}" not in q for _, q in qs)


def test_summarize_matrix():
    result = [
        {"metric": {"route": "GET /api/debug/error", "status": "500"}, "values": [[1, "0.1"], [2, "0.5"], [3, "1.2"]]},
        {"metric": {"route": "GET /api/products", "status": "500"}, "values": [[1, "0.01"], [2, "0.01"]]},
        {"metric": {}, "values": [[1, "NaN"]]},
    ]
    lines = context.summarize_matrix(result)
    assert lines[0].startswith('route="GET /api/debug/error",status="500"')
    assert "最大=1.2" in lines[0] and "趋势=上升" in lines[0]
    assert "趋势=平稳" in lines[1]


def test_summarize_matrix_limits_series():
    result = [{"metric": {"pod": f"p{i}"}, "values": [[1, str(i)]]} for i in range(20)]
    lines = context.summarize_matrix(result, max_series=5)
    assert len(lines) == 6 and "另有 15 条" in lines[-1]
    assert lines[0].startswith('pod="p19"')


def test_summarize_logs_dedup_and_redact():
    line = json.dumps({"level": "ERROR", "msg": "access", "route": "GET /api/debug/error", "status": 500,
                       "request_id": "r1"})
    db = json.dumps({"level": "ERROR", "msg": "list products failed",
                     "err": "dial mall:MallPass123@tcp(10.0.0.1:3306) refused"})
    streams = [{"values": [["1", line]] * 5 + [["2", db], ["3", "not json"]]}]
    out = context.summarize_logs(streams)
    assert out[0].startswith("5 次 ERROR msg=access route=GET /api/debug/error status=500")
    assert "样例request_id=r1" in out[0]
    assert all("MallPass123" not in x for x in out)


def test_summarize_pods_and_events():
    pods = {"items": [{"metadata": {"name": "mall-api-1"}, "status": {"phase": "Running", "containerStatuses": [
        {"ready": False, "restartCount": 4, "state": {"waiting": {"reason": "CrashLoopBackOff"}},
         "lastState": {"terminated": {"reason": "OOMKilled", "exitCode": 137, "finishedAt": "2026-11-24T08:00:00Z"}}}
    ]}}]}
    line = context.summarize_pods(pods)[0]
    assert "restarts=4" in line and "waiting(CrashLoopBackOff)" in line and "OOMKilled" in line
    events = {"items": [
        {"type": "Warning", "reason": "BackOff", "count": 3, "message": "Back-off restarting",
         "involvedObject": {"kind": "Pod", "name": "mall-api-1"}, "lastTimestamp": "2026-11-24T08:10:00Z"},
        {"type": "Normal", "reason": "Pulled", "involvedObject": {"kind": "Pod", "name": "mall-api-1"},
         "lastTimestamp": "2026-11-24T08:10:00Z"},
        {"type": "Warning", "reason": "Old", "involvedObject": {"kind": "Pod", "name": "mall-api-1"},
         "lastTimestamp": "2026-11-23T00:00:00Z"},
        {"type": "Warning", "reason": "Other", "involvedObject": {"kind": "Pod", "name": "mall-web-1"},
         "lastTimestamp": "2026-11-24T08:10:00Z"},
    ]}
    since = context._parse_ts("2026-11-24T08:00:00Z")
    ev = context.summarize_events(events, since, name_prefix="mall-api")
    assert ev == ["Pod/mall-api-1 BackOff x3: Back-off restarting"]


def test_collector_tolerates_source_failures():
    def handler(req: httpx.Request):
        if "loki" in req.url.host:
            return httpx.Response(500, text="boom")
        return httpx.Response(200, json={"status": "success", "data": {"resultType": "matrix", "result": [
            {"metric": {"route": "GET /api/debug/error"}, "values": [[1, "1"], [2, "2"]]}]}})

    s = Settings.from_env({"K8S_ENABLED": "false", "LOKI_URL": "http://loki.test", "PROM_URL": "http://prom.test"})
    col = context.Collector(s, http=httpx.Client(transport=httpx.MockTransport(handler)))
    ctx = col.collect(group_alerts(PAYLOAD)[0], now=1_800_000_000)
    assert any("最新=2" in x for x in ctx["prometheus"])
    assert ctx["loki"][0].startswith("Loki 查询失败：HTTPStatusError")
    assert ctx["kubernetes"] == ["（未启用 K8s 采集）"]


# ---------------------------------------------------------------- 提示词与输出解析


def test_build_messages_contains_rules_and_context():
    g = group_alerts(PAYLOAD)[0]
    ctx = FakeCollector().collect(g)
    msgs = prompt.build_messages(g, ctx)
    assert "只输出一个 JSON 对象" in msgs[0]["content"]
    assert "不要编造" in msgs[0]["content"]
    user = msgs[1]["content"]
    assert "告警名：MallApiHighErrorRate" in user and "debug error triggered" in user
    assert user.index("Prometheus") < user.index("Loki") < user.index("Kubernetes")


def test_render_context_truncates_each_section():
    ctx = {"prometheus": ["x" * 5000], "loki": ["y" * 10], "kubernetes": ["z" * 10]}
    text = prompt.render_context(ctx, max_chars=900)
    assert "已截断" in text and "y" * 10 in text and "z" * 10 in text


@pytest.mark.parametrize("raw", [
    GOOD_OUTPUT,
    "```json\n" + GOOD_OUTPUT + "\n```",
    "好的，分析如下：\n" + GOOD_OUTPUT + "\n以上。",
])
def test_parse_output_variants(raw):
    out = prompt.parse_output(raw)
    assert out["summary"].startswith("mall-api 5xx")
    cmds = {c["cmd"]: c for c in out["commands"]}
    assert cmds["kubectl -n mall logs deploy/mall-api --tail=50"]["risk"] == "read-only"
    # 模型说是只读，本地规则复核为会改变系统
    assert cmds["kubectl -n mall set env deploy/mall-api MALL_DEBUG=false"]["risk"] == "change"
    # 高危命令被丢掉
    assert "kubectl delete ns mall" not in cmds
    assert out["need_human"] is True


@pytest.mark.parametrize("raw", ["", "不是 JSON", "[1,2]", '{"possible_causes": []}', "{bad json}"])
def test_parse_output_invalid(raw):
    assert prompt.parse_output(raw) is None


def test_normalize_caps_and_defaults():
    obj = {"summary": "s", "possible_causes": [{"cause": f"c{i}", "confidence": "极高"} for i in range(9)],
           "steps": [f"s{i}" for i in range(9)], "commands": ["kubectl get pod -n mall"]}
    out = prompt.normalize(obj)
    assert len(out["possible_causes"]) == 3 and out["possible_causes"][0]["confidence"] == "low"
    assert len(out["steps"]) == 5
    assert out["commands"] == [{"cmd": "kubectl get pod -n mall", "where": "-", "risk": "read-only"}]


# ---------------------------------------------------------------- 大模型客户端


def test_chat_client_ok_and_errors():
    def ok(req):
        body = json.loads(req.content)
        assert body["response_format"] == {"type": "json_object"}
        assert req.headers["authorization"] == "Bearer k"
        return httpx.Response(200, json={"choices": [{"message": {"content": "hi"}}]})

    c = ChatClient("http://llm.test/v1", "k", "m", 5, json_mode=True, transport=httpx.MockTransport(ok))
    assert c.chat([{"role": "user", "content": "x"}]) == "hi"

    c2 = ChatClient("http://llm.test/v1", "k", "m", 5, transport=httpx.MockTransport(
        lambda r: httpx.Response(429, text="rate limited")))
    with pytest.raises(LLMError, match="429"):
        c2.chat([])

    def timeout(req):
        raise httpx.ReadTimeout("slow", request=req)

    c3 = ChatClient("http://llm.test/v1", "k", "m", 5, transport=httpx.MockTransport(timeout))
    with pytest.raises(LLMError, match="ReadTimeout"):
        c3.chat([])


# ---------------------------------------------------------------- 通知格式


def test_format_analysis_has_feedback_links_and_risk_mark():
    g = group_alerts(PAYLOAD)[0]
    a = prompt.parse_output(GOOD_OUTPUT)
    text = notify.format_analysis(g, a, "abc123", "http://alert-analyzer.lab.local", suppressed=2)
    assert "【P2 重要】MallApiHighErrorRate" in text
    assert "【会改变系统，需人工确认】" in text
    assert "http://alert-analyzer.lab.local/feedback/abc123?vote=up" in text
    assert "另有 2 次相同告警" in text


def test_format_truncates_to_wecom_limit():
    g = group_alerts(PAYLOAD)[0]
    ctx = {"prometheus": ["中" * 3000] * 6}
    assert len(notify.format_fallback(g, ctx, "x", "id").encode()) <= notify.MAX_BYTES


def test_notifier_dry_run_and_wecom():
    s = Settings.from_env({})
    n = notify.Notifier(s, http=httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(500))))
    assert n.send("t", "hello") == ["dry-run"] and n.dry_run_messages == ["hello"]

    def wecom(req):
        assert json.loads(req.content) == {"msgtype": "markdown", "markdown": {"content": "hello"}}
        return httpx.Response(200, json={"errcode": 0, "errmsg": "ok"})

    s.wecom_webhook = "https://qyapi.example/cgi-bin/webhook/send?key=K"
    n2 = notify.Notifier(s, http=httpx.Client(transport=httpx.MockTransport(wecom)))
    assert n2.send("t", "hello") == ["wecom:ok"]


def test_dingtalk_signed_url():
    url = notify.dingtalk_signed_url("https://oapi.dingtalk.com/robot/send?access_token=T", "SEC1", now_ms=1)
    assert url.startswith("https://oapi.dingtalk.com/robot/send?access_token=T&timestamp=1&sign=")


# ---------------------------------------------------------------- 端到端（FastAPI + 假依赖）


def test_webhook_ok_then_cooldown_then_feedback(tmp_path):
    client, col, nt, st = make_client(tmp_path, llm=FakeLLM())
    r = client.post("/alertmanager", json=PAYLOAD)
    assert r.status_code == 200 and r.json()["accepted"] == ["MallApiHighErrorRate|mall|warning"]
    assert len(nt.sent) == 1 and "AI 分析" in nt.sent[0][1]

    # 冷却期内再来一次：不分析、不推送
    r2 = client.post("/alertmanager", json=PAYLOAD)
    assert r2.json()["accepted"] == [] and len(nt.sent) == 1 and col.calls == 1

    rid = nt.sent[0][1].split("分析编号：")[1].strip()
    assert client.get(f"/feedback/{rid}?vote=up").status_code == 200
    assert client.get(f"/feedback/{rid}?vote=bad").status_code == 400
    assert client.get("/feedback/nope?vote=up").status_code == 404
    stats = client.get("/stats").json()
    assert stats["ok"] == 1 and stats["feedback_up"] == 1 and stats["useful_ratio"] == 1.0
    assert 'alert_analyzer_analyses_total{result="ok"} 1' in client.get("/metrics").text


def test_resolved_resets_cooldown(tmp_path):
    client, col, nt, st = make_client(tmp_path, llm=FakeLLM())
    client.post("/alertmanager", json=PAYLOAD)
    resolved = {"alerts": [dict(a, status="resolved") for a in PAYLOAD["alerts"]]}
    client.post("/alertmanager", json=resolved)
    client.post("/alertmanager", json=PAYLOAD)
    assert len(nt.sent) == 2


def test_fallback_when_llm_down(tmp_path):
    client, col, nt, st = make_client(tmp_path, llm=FakeLLM(exc=TimeoutError("llm timeout")))
    client.post("/alertmanager", json=PAYLOAD)
    text = nt.sent[0][1]
    assert "AI 分析不可用" in text and "TimeoutError" in text
    assert "debug error triggered" in text  # 原始上下文照样推送
    assert client.get("/stats").json()["fallback"] == 1


def test_fallback_when_llm_output_invalid(tmp_path):
    client, _, nt, _ = make_client(tmp_path, llm=FakeLLM(reply="我觉得是数据库的问题"))
    client.post("/alertmanager", json=PAYLOAD)
    assert "大模型输出不是合法 JSON" in nt.sent[0][1]


def test_no_llm_configured_still_notifies(tmp_path):
    client, _, nt, _ = make_client(tmp_path, llm=None)
    client.post("/alertmanager", json=PAYLOAD)
    assert "未配置大模型" in nt.sent[0][1]


def test_info_severity_skipped(tmp_path):
    client, _, nt, _ = make_client(tmp_path, llm=FakeLLM())
    p = json.loads(json.dumps(PAYLOAD))
    for a in p["alerts"]:
        a["labels"]["severity"] = "info"
    assert client.post("/alertmanager", json=p).json()["accepted"] == []
    assert nt.sent == []


def test_bad_json_returns_400(tmp_path):
    client, *_ = make_client(tmp_path, llm=FakeLLM())
    assert client.post("/alertmanager", content=b"not json",
                       headers={"Content-Type": "application/json"}).status_code == 400
