# AIOps-2 告警智能分析

对应教程：《AIOps-2 告警智能分析》。Alertmanager 告警抄送给 alert-analyzer，它采集近 15 分钟的指标、错误日志、Pod 状态和事件，
调大模型生成"可能原因 + 排查步骤 + 建议命令"，推送到企业微信 / 钉钉。大模型不可用时降级推送原始告警和采集到的上下文。

## 文件
| 路径 | 用途 |
|---|---|
| `analyzer/main.py` | FastAPI 服务：`/alertmanager`、`/feedback/{id}`、`/stats`、`/metrics`、`/healthz` |
| `analyzer/aggregator.py` | 告警分组（告警名 + 命名空间 + 级别）和冷却时间 |
| `analyzer/context.py` | Prometheus / Loki / K8s 上下文采集，并在本地压缩成摘要 |
| `analyzer/prompt.py` | 提示词（角色、上下文、JSON 输出格式、禁止事项）、输出解析、命令风险复核 |
| `analyzer/llm.py` | OpenAI 兼容 Chat Completions 客户端（httpx，带超时） |
| `analyzer/notify.py` | 群消息格式化（分析版 / 降级版）和推送 |
| `analyzer/store.py` | SQLite 记录分析结果和"有用 / 没用"反馈 |
| `analyzer/redact.py` | 发给模型前的脱敏 |
| `tests/test_analyzer.py` | 单元测试，全部依赖用假的，不联网 |
| `Dockerfile` | 镜像（python:3.13-slim，非 root） |
| `k8s/` | RBAC（只读 mall 的 Pod / 事件）、ConfigMap、Secret 示例、Deployment + Service、ServiceMonitor + 告警、HTTPRoute、PVC 示例 |
| `alertmanager/alertmanager-values-ai.yaml` | 在 Lab 09 的 Alertmanager 配置里加"抄送 AI 分析"的路由片段 |
| `scripts/test-payload.json` | Alertmanager webhook 示例（MallApiHighErrorRate） |
| `scripts/send-test-alert.sh` | 直接把示例告警发给服务 |
| `scripts/trigger-real-alert.sh` | 用 `/api/debug/error` 制造真实 5xx，触发完整链路 |

## 本地运行
```bash
cd labs/aiops-2-alert-analysis
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
python -m pytest -q
# 不在集群里：关掉 K8s 采集；Prometheus / Loki 可以 port-forward 过来
K8S_ENABLED=false DB_PATH=/tmp/analyzer.db PROM_URL=http://127.0.0.1:9090 LOKI_URL=http://127.0.0.1:3100 \
LLM_BASE_URL=https://llm.example.com/v1 LLM_API_KEY=sk-REPLACE_ME LLM_MODEL=your-chat-model \
uvicorn --factory analyzer.main:create_app --port 8080
URL=http://127.0.0.1:8080 bash scripts/send-test-alert.sh
```

## 部署到 K8s（k8s-master）
```bash
docker build -t harbor.lab.local/ops/alert-analyzer:v1.0.0 labs/aiops-2-alert-analysis   # 在 lab-dev 构建
docker push harbor.lab.local/ops/alert-analyzer:v1.0.0
cp k8s/secret.example.yaml k8s/secret.yaml && vi k8s/secret.yaml
kubectl apply -f k8s/secret.yaml
kubectl apply -k k8s/
```

## 写作时版本
| 组件 | 版本 |
|---|---|
| FastAPI | 0.165.0 |
| Uvicorn | 0.54.0 |
| httpx | 0.28.1 |
| Alertmanager webhook | payload version 4，`webhook_configs.timeout` 字段可用 |

以官方文档最新版本为准。

## 和其他实验的约定
- Prometheus：Lab 09 的 `kube-prometheus-stack-prometheus.monitoring.svc:9090`。
- Loki：默认 `loki-gateway.logging.svc`，日志流标签默认 `namespace`、`container`，和 Lab 10 的采集配置不一致时改 ConfigMap 的 `LOKI_URL`、`LOKI_SELECTOR`。
- Gateway：Lab 09 的 `envoy-gateway-system/lab-gateway`。
- 原始告警仍走 Lab 09 的 alert-bridge，本服务只"抄送"。
