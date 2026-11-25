# SRE-1 链路追踪与 SLO

对应教程：《DevOps 运维实战》进阶-SRE / SRE-1-链路追踪与SLO。

## 文件

| 文件 | 用途 |
|---|---|
| `tracing/jaeger.yaml` | Jaeger v2 all-in-one（内存存储），部署在 `monitoring` |
| `tracing/otel-collector.yaml` | OpenTelemetry Collector：收 OTLP，转发给 Jaeger |
| `tracing/envoyproxy-tracing.yaml` | Envoy Gateway 的 EnvoyProxy 配置，打开网关 OpenTelemetry 追踪 |
| `tracing/gateway-infra-patch.yaml` | 让 Gateway 引用上面的 EnvoyProxy |
| `tracing/httproute-jaeger.yaml` | 通过网关暴露 `jaeger.lab.local` |
| `slo/rules/mall-api-slo.rules.yml` | 手写的 SLI 记录规则、错误预算规则、多窗口多燃烧率告警（标准 Prometheus 规则格式） |
| `slo/rules/mall-api-slo.rules.test.yml` | 上面规则的 promtool 单元测试 |
| `slo/sloth/mall-api.sloth.yml` | 同样两个 SLO 的 Sloth 规范 |
| `slo/sloth/generated/mall-api.rules.yml` | Sloth v0.16.0 生成的规则（和手写版二选一，记录规则同名，不能同时加载） |
| `slo/grafana/mall-api-slo-dashboard.json` | Grafana 大盘：SLI、剩余预算、燃烧率（配合手写规则） |
| `slo/alertmanager-slo-route.yaml` | Alertmanager 按 `notify=page/ticket` 分流的 values 片段 |
| `slo/error-budget-policy.md` | 错误预算政策模板 |
| `scripts/make-prometheusrule.sh` | 把规则文件包装成 PrometheusRule 资源 |
| `scripts/gen-traffic.sh` | 造背景流量，可按比例混入 500 和慢请求，用来烧预算 |
| `scripts/slo-report.sh` | 从 Prometheus 读出 SLO 状态打印成表 |
| `homework/` | 课后作业：mall-api 接入 OTel SDK 的补丁、上线配置、Grafana 的 Jaeger 数据源，见 `homework/README.md` |

## 前提假设（和你的环境不一致就替换）

| 项目 | 本目录默认值 | 来源 |
|---|---|---|
| mall-api 命名空间 / Deployment | `mall` / `mall-api` | Lab 06 |
| 共享 Gateway | `lab-gateway`，命名空间 `envoy-gateway-system` | Lab 06，`kubectl get gateway -A` 确认 |
| mall-api 指标标签 | `job="mall-api"`、`namespace="mall"` | Lab 09 的 ServiceMonitor（同时抓 mall / mall-staging / mall-prod） |
| kube-prometheus-stack release 名 | `kube-prometheus-stack`（命名空间 `monitoring`），`ruleSelectorNilUsesHelmValues: false` | Lab 09 |
| Loki 数据源 | `Loki-mall`（租户 mall），日志标签 `namespace` `app` | Lab 10 |
| Prometheus 地址 | `http://prometheus.lab.local` | Lab 09 的 HTTPRoute |

## 校验

```bash
promtool check rules slo/rules/mall-api-slo.rules.yml slo/sloth/generated/mall-api.rules.yml
promtool test rules slo/rules/mall-api-slo.rules.test.yml
sloth validate -i slo/sloth/mall-api.sloth.yml
```

## 写作时版本

Envoy Gateway v1.10.0、OpenTelemetry Collector contrib 0.165.0（0.166.0 于 2026-11-24 发布，写作时 contrib 的二进制还没上传完，先用 0.165.0）、Jaeger v2.23.0、Sloth v0.16.0、Prometheus v3.16.0，集群按 Kubernetes v1.37。以各项目官方文档为准。

## 验证记录

在 Ubuntu 24.04 容器里真跑通过：

- `promtool check rules`（promtool v3.16.0）：手写规则 29 条、Sloth 生成规则 34 条
- `promtool test rules slo/rules/mall-api-slo.rules.test.yml`：通过。验证时发现快烧告警的 description 期望值（当前错误比例）和 v3.16.0 的计算结果不一致（期望 5.097%，实际 4.969%，差异来自 `rate()` 的外推），已按 v3.16.0 的实测值修正测试，规则本身没改
- `sloth validate` 通过；`sloth generate`（v0.16.0）生成的规则除第一行版权注释外和 `slo/sloth/generated/mall-api.rules.yml` 一致
- `tracing/otel-collector.yaml` 里的 Collector 配置用 otelcol-contrib 0.165.0 `validate` 通过
- 脚本 `shellcheck` + `bash -n` 通过

没有验证：Jaeger、OTel Collector、Envoy Gateway 追踪、PrometheusRule、Grafana 大盘、Alertmanager 路由等所有 K8s 部分（不连集群，只做 YAML 语法检查）；`gen-traffic.sh`、`slo-report.sh` 依赖集群里的 mall-api 和 Prometheus，没有跑。
