# Lab 09 监控告警体系建设：实验代码

对应教程：《DevOps 运维实战》→ DevOps 核心实验 → Lab 09 监控告警体系建设。

## 文件清单

| 文件 | 用途 | 在哪执行 |
|---|---|---|
| `values/kube-prometheus-stack-values.yaml` | kube-prometheus-stack 实验环境 values：单副本、保留 3 天 / 4GiB、全部组件写资源限制、放开 ServiceMonitor/ScrapeConfig/规则的选择器 | k8s-master |
| `values/alertmanager-values.yaml` | Alertmanager 路由（P1/P2/P3）、分组、抑制、夜间静音时段、webhook 接收人 | k8s-master |
| `manifests/httproutes.yaml` | Gateway API 暴露 `grafana.lab.local`、`prometheus.lab.local` | k8s-master |
| `manifests/servicemonitor-mall-api.yaml` | 自动发现 mall / mall-staging / mall-prod 里的 mall-api，抓 `/metrics` | k8s-master |
| `manifests/scrapeconfig-vms.yaml` | ScrapeConfig 静态抓取虚拟机上的 node_exporter、mysqld_exporter、redis_exporter | k8s-master |
| `manifests/prometheusrule-mall-api.yaml` | mall-api 记录规则（QPS、错误率、P95/P99）和告警（服务不可用、错误率、延迟、Pod 重启、OOM） | k8s-master |
| `manifests/prometheusrule-infra.yaml` | 主机、磁盘预测、MySQL（宕机、复制中断、主从延迟、连接数）、Redis、exporter 告警 | k8s-master |
| `dashboards/ops-mall-overview.json` | ops-mall 业务大盘（QPS、错误率、延迟、订单数、缓存命中率、实例数、版本） | — |
| `dashboards/kustomization.yaml` | 把大盘打包成带 `grafana_dashboard: "1"` 标签的 ConfigMap，sidecar 自动导入 | k8s-master |
| `alert-bridge/` | Alertmanager webhook → 企业微信 / 钉钉群机器人的转换服务（Python 标准库，单文件） | k8s-master |
| `exporters/install-exporters.sh` | 虚拟机上安装三种 exporter（二进制 + systemd + 防火墙 + sha256 校验） | lab-web1/2、lab-db1/2 |
| `exporters/mysql-exporter-user.sql` | mysqld_exporter 只读监控账号 | lab-db1 |
| `scripts/fire-drill.sh` | 用 `/api/debug/error`、`/api/debug/slow` 制造故障，验证告警链路 | 学员电脑或任一虚拟机 |
| `tests/rules.test.yaml`、`tests/run-rule-tests.sh` | promtool 告警规则单元测试 | 学员电脑 |

## 写作时版本

| 组件 | 版本 |
|---|---|
| kube-prometheus-stack chart | 93.9.0（Prometheus Operator v0.95.2） |
| Prometheus / Alertmanager / Grafana | v3.16.0 / v0.35.0 / 13.3.1 |
| node_exporter / mysqld_exporter / redis_exporter | 1.13.1 / 0.21.0 / 1.99.0 |

以官方最新文档为准：<https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack>

## 快速开始

```bash
# k8s-master
helm upgrade --install kube-prometheus-stack \
  oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
  --version 93.9.0 -n monitoring --create-namespace \
  -f values/kube-prometheus-stack-values.yaml -f values/alertmanager-values.yaml

kubectl apply -f manifests/
kubectl apply -k dashboards/
kubectl apply -k alert-bridge/
# 有真实机器人时：cp alert-bridge/secret.example.yaml secret.yaml，填好后 kubectl apply -f secret.yaml
```

```bash
# lab-web1 lab-web2 lab-db1 lab-db2（root）
./install-exporters.sh node
# lab-db1 先建账号：mysql -uroot -p < mysql-exporter-user.sql
# lab-db1 lab-db2
MYSQL_EXPORTER_PASSWORD='ExporterPass123' ./install-exporters.sh mysqld
# lab-db1
./install-exporters.sh redis
```

## 需要按实际环境修改的地方

- `manifests/httproutes.yaml` 的 `parentRefs`：假设 Lab 06 的 Gateway 叫 `lab-gateway`、在 `envoy-gateway-system` 命名空间。
- `manifests/servicemonitor-mall-api.yaml` 假设 mall-api 的 Service 带 `app.kubernetes.io/name: mall-api` 标签，端口名是 `http`。
- 虚拟机 IP 写死在 `manifests/scrapeconfig-vms.yaml`，网段不是 192.168.56.0/24 时要改。

## 规则测试

```bash
cd tests && ./run-rule-tests.sh
```

需要 `promtool` 和 `yq`。测试覆盖：错误率两档阈值、低流量不误报、服务整体不可用、P99/P95 延迟、磁盘 24 小时写满预测、MySQL 8.4 列名的主从延迟和复制中断。
