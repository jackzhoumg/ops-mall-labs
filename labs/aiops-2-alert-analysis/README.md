# AIOps-2 告警智能分析

对应教程：《AIOps-2 告警智能分析》。主线用 CNCF 开源项目 **HolmesGPT**：接入 Prometheus、Loki、Kubernetes 和 OpenAI 兼容模型，调查 Alertmanager 里正在响的告警，结论经 PrometheusAlert 推到企业微信群；K8sGPT 作对比。自写的 alert-analyzer 保留为"原理拆解（选做）"。

## 文件

| 路径 | 用途 |
|---|---|
| `holmes/config.example.yaml` | 主线：HolmesGPT 命令行配置（复制到 `~/.holmes/config.yaml`），Prometheus、Loki（多租户 `mall`）数据源，关掉 `internet`、`robusta` |
| `holmes/values.yaml` | 主线：Helm Chart `robusta/holmes` 0.47.0 的 values：自定义只读 SA、OpenAI 兼容模型、API 密钥、数据源、关掉外发类工具集 |
| `holmes/rbac-namespace-scoped.yaml` | 主线：ServiceAccount `holmes`，只读 `mall` 和 `monitoring`，没有 Secret 权限 |
| `holmes/cronjob-investigate.yaml` | 主线（可选）：每 30 分钟调查 critical 告警，`--destination webhook` 推给 PrometheusAlert |
| `holmes/prometheusalert-holmes-template.json` | 主线：PrometheusAlert 自定义模板 `holmes-wx`，把 HolmesGPT 的 webhook 报文渲染成企业微信消息 |
| `analyzer/` | 原理拆解：FastAPI 告警分析服务（分组冷却、上下文采集压缩、提示词、命令风险复核、降级） |
| `tests/test_analyzer.py` | 原理拆解：单元测试，全部依赖用假的，不联网 |
| `Dockerfile` | 原理拆解：镜像（python:3.13-slim，非 root） |
| `k8s/` | 原理拆解：RBAC、ConfigMap、Secret 示例、Deployment + Service、ServiceMonitor + 告警、HTTPRoute、PVC 示例 |
| `alertmanager/alertmanager-values-ai.yaml` | 原理拆解：在 Lab 09 的 Alertmanager 配置里加 `continue: true` 抄送路由 |
| `scripts/test-payload.json`、`scripts/send-test-alert.sh` | 原理拆解：直接把示例告警发给 alert-analyzer |
| `scripts/trigger-real-alert.sh` | 用 `/api/debug/error` 制造真实 5xx，触发 `MallApiHighErrorRate`（主线和原理拆解都用） |

## 主线：HolmesGPT

```bash
# lab-dev（Ubuntu 24.04）：命令行
sudo apt install -y pipx && pipx ensurepath
pipx install holmesgpt==0.47.0
mkdir -p ~/.holmes && cp holmes/config.example.yaml ~/.holmes/config.yaml
export OPENAI_API_BASE=https://llm.example.com/v1
read -rsp 'llm key: ' OPENAI_API_KEY && export OPENAI_API_KEY && echo
holmes toolset refresh
holmes investigate alertmanager --alertmanager-label severity=critical -n 3 --model openai/your-chat-model

# k8s-master：集群内常驻
kubectl apply -f holmes/rbac-namespace-scoped.yaml
kubectl -n monitoring create secret generic holmes-llm \
  --from-literal=OPENAI_API_KEY='sk-REPLACE_ME' --from-literal=HOLMES_API_KEY="$(openssl rand -hex 24)"
helm repo add robusta https://robusta-charts.storage.googleapis.com && helm repo update
helm upgrade --install holmes robusta/holmes --version 0.47.0 -n monitoring -f holmes/values.yaml

# 推送到群（可选）：先把 holmes/prometheusalert-holmes-template.json 追加进 Lab 09 的模板文件
kubectl -n monitoring create secret generic holmes-webhook --from-literal=WEBHOOK_URL='http://prometheusalert.monitoring.svc:8080/prometheusalert?type=wx&tpl=holmes-wx&wxurl=https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=REPLACE_ME'
kubectl apply -f holmes/cronjob-investigate.yaml
```

## 原理拆解（选做）：alert-analyzer

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt   # 国内：-i https://mirrors.aliyun.com/pypi/simple/
python -m pytest -q
# 不在集群里：关掉 K8s 采集；Prometheus / Loki 用网关域名或 port-forward
K8S_ENABLED=false DB_PATH=/tmp/analyzer.db PROM_URL=http://prometheus.lab.local LOKI_URL=http://loki.lab.local LOKI_TENANT=mall \
LLM_BASE_URL=https://llm.example.com/v1 LLM_API_KEY=sk-REPLACE_ME LLM_MODEL=your-chat-model \
uvicorn --factory analyzer.main:create_app --port 8080
URL=http://127.0.0.1:8080 bash scripts/send-test-alert.sh
# 部署：docker build -t harbor.lab.local/ops/alert-analyzer:v1.0.0 . && docker push ...；kubectl apply -f k8s/secret.yaml && kubectl apply -k k8s/
```

## 写作时版本

| 组件 | 版本 |
|---|---|
| HolmesGPT | 0.47.0（PyPI `holmesgpt`；Helm Chart `robusta/holmes` 0.47.0；镜像 `robustadev/holmes:0.47.0`） |
| K8sGPT | v0.4.41 |
| PrometheusAlert | v5.0.0（Lab 09） |
| Kubernetes | v1.37 |
| 原理拆解：FastAPI / Uvicorn / httpx | 0.165.0 / 0.54.0 / 0.28.1 |

以官方文档最新版本为准。

## 和其他实验的约定

- Prometheus：Lab 09 的 `kube-prometheus-stack-prometheus.monitoring.svc:9090`；集群外 `http://prometheus.lab.local`。
- Alertmanager：`kube-prometheus-stack-alertmanager.monitoring.svc:9093`；集群外 `http://alertmanager.lab.local`。
- Loki：Lab 10 的 `loki-gateway.logging.svc.cluster.local`，开了多租户，mall-api 的日志在租户 `mall`（请求头 `X-Scope-OrgID: mall`）。
- 原始告警仍走 Lab 09 的 Alertmanager → PrometheusAlert → 群，本实验只另发"AI 分析"。

## 验证记录

验证环境：讲师实验机，全部在容器里做（Ubuntu 24.04.5 systemd 容器 + Prometheus v3.16.0、Alertmanager v0.35.1、Loki 3.7.10、PrometheusAlert v5.0.0 容器）。**没有模型 Key，没有连 K8s 集群**。

已验证：
- `apt install pipx` + `pipx install holmesgpt==0.47.0` 在 Ubuntu 24.04（Python 3.12.3）上成功，`holmes version` 输出 `0.47.0`。
- 按 `config.example.yaml` 的结构配好 Prometheus、Loki（带 `X-Scope-OrgID`）后，`holmes toolset list` / `refresh` 里 `prometheus/metrics`、`grafana/loki` 为 enabled，`internet` 为 disabled；故意写错 `prometheus_url` 时报 `Failed to initialize using url=http://127.0.0.1:9999/api/v1/query?query=up`。
- 往 Alertmanager 推一条 `MallApiHighErrorRate` 测试告警后，`holmes investigate alertmanager --alertmanager-label severity=critical` 能拉到告警并开始调查（`Loading alerts from url .../api/v2/alerts`、`Analyzing issue 1/1: MallApiHighErrorRate...`），在调模型这一步因为没有可用模型停止（`litellm.InternalServerError ... Connection error`）。
- 用一个假的 OpenAI 兼容接口（固定回答、不调工具）代替模型，按 `cronjob-investigate.yaml` 的参数（`--config`、`-n 3`、`--destination webhook`、`WEBHOOK_URL` 指向 PrometheusAlert）跑通：`Successfully sent issue to Webhook`；PrometheusAlert 导入 `prometheusalert-holmes-template.json` 返回 `holmes-wx：导入完成`，发给（模拟的）企业微信端点的报文是 `{"msgtype":"markdown","markdown":{"content":"### 【AI 分析】MallApiHighErrorRate\n\n...\n\n> HolmesGPT 自动分析，仅供参考，以实际排查为准。"}}`。
- 同一个假接口记录了 HolmesGPT 发给模型的第一次请求：系统提示词约 2.6 万字符、告警原文约 1 千字符，工具列表包括 `grafana_loki_query`、`get_metric_names` 等；关掉 `bash` 后工具列表里没有 `bash`。教程 5.8 的数据外发表格依据这次记录。
- 发现并写进教程：工具集状态有缓存，配置改过以后要 `holmes toolset refresh`；`/api/v2/alerts` 的请求参数是 `active=true&silenced=false&inhibited=false`（源码），被抑制的告警不会被调查。
- `helm template holmes robusta/holmes 0.47.0 -f holmes/values.yaml --kube-version 1.37.0`（Chart 包从 robusta-charts 下载到本地渲染）：成功，生成 ConfigMap、Service `holmes-holmes`、Deployment；Deployment 用 SA `holmes`、镜像 `robustadev/holmes:0.47.0`，工具集里 `bash`、`internet`、`robusta` 为 false，Loki 带租户头，`OPENAI_API_KEY` / `HOLMES_API_KEY` 来自 Secret。
- 原理拆解：Ubuntu 24.04 Python 3.12.3 venv 安装 `requirements-dev.txt` 后 `pytest` 33 个测试通过。
- YAML 用 `yamlcheck.js` 检查通过。

没验证：
- 有真实模型时的调查结论、`holmes ask`、5.10 的真实告警演练、K8sGPT（没有模型 Key、没有集群）。
- Helm 安装到集群、`kubectl auth can-i` 的结果、HTTP API `/api/chat`、CronJob 在集群里运行（按规则不连 K8s 集群，集群验证由讲师安排）。教程里这几处的输出是示意。
- 真实企业微信群推送（用的是模拟端点）。
