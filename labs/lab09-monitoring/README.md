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
| `prometheusalert/deployment.yaml`、`prometheusalert/kustomization.yaml` | 开源告警网关 PrometheusAlert v5.0.0：Alertmanager webhook → 企业微信 / 钉钉群机器人；启动后自动导入 Git 里的模板 | k8s-master |
| `prometheusalert/ops-mall-templates.json` | 企业微信消息模板 `ops-mall-wx`（按 severity 显示 P1/P2/P3、恢复消息、北京时间） | — |
| `prometheusalert/alertmanager-robots.example.yaml` | Secret 示例：Alertmanager 用 `url_file` 读取的 PrometheusAlert 地址（含群机器人 key），**复制到仓库外再填真实 key** | k8s-master |
| `prometheusalert/test-payload.json` | 手工测试用的 Alertmanager webhook 报文（内容注明“课程测试”） | k8s-master |
| `exporters/install-exporters.sh` | Ubuntu 24.04 虚拟机上安装三种 exporter（官方二进制 + systemd + sha256 校验；ufw 已启用时只对实验网段放行端口） | lab-web1/2、lab-db1/2 |
| `exporters/mysql-exporter-user.sql` | mysqld_exporter 只读监控账号 | lab-db1 |
| `scripts/fire-drill.sh` | 用 `/api/debug/error`、`/api/debug/slow` 制造故障，验证告警链路 | 学员电脑或任一虚拟机 |
| `tests/rules.test.yaml`、`tests/run-rule-tests.sh` | promtool 告警规则单元测试 | 学员电脑 |

## 写作时版本

| 组件 | 版本 |
|---|---|
| kube-prometheus-stack chart | 93.10.1（Prometheus Operator v0.95.2，chart 要求 K8s >= 1.25） |
| Prometheus / Alertmanager / Grafana | v3.16.0 / v0.35.1 / 13.3.2 |
| PrometheusAlert | v5.0.0（`feiyu563/prometheus-alert:v5.0.0`） |
| node_exporter / mysqld_exporter / redis_exporter | 1.13.1 / 0.21.0 / 1.99.0 |

以官方最新文档为准：<https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack>

## 快速开始

```bash
# k8s-master
# Alertmanager 挂载 Secret alertmanager-robots，先建一个占位的，否则 Pod 起不来
kubectl create namespace monitoring
kubectl apply -f prometheusalert/alertmanager-robots.example.yaml
helm upgrade --install kube-prometheus-stack \
  oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
  --version 93.10.1 -n monitoring --create-namespace \
  -f values/kube-prometheus-stack-values.yaml -f values/alertmanager-values.yaml

kubectl apply -f manifests/
kubectl apply -k dashboards/
kubectl -n monitoring create secret generic prometheusalert-auth --from-literal=login_password='你自己的密码'
kubectl apply -k prometheusalert/
# 有真实机器人时：cp prometheusalert/alertmanager-robots.example.yaml ~/alertmanager-robots.yaml，填好 key 后 kubectl apply -f ~/alertmanager-robots.yaml
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
## 验证记录
写作时在一台 Ubuntu 24.04 实验机上用 Docker 做了验证（不是 K8s 集群），结果如下。

已验证：
- `promtool check rules`（Prometheus v3.16.0 镜像）：两个规则文件各 14 条，SUCCESS；`promtool test rules tests/rules.test.yaml`：SUCCESS（磁盘测试数据已改成 Ubuntu 默认的 ext4 + LVM 设备名）。
- `amtool check-config`（Alertmanager v0.35.1 镜像，配置用 `yq '.alertmanager.config'` 从 values 抽出）：SUCCESS，4 条抑制规则、3 个接收人；`amtool config routes test`：critical → `oncall-p1`，warning → `ops-wecom`，Watchdog → `null`，info → `ops-wecom`。
- `helm template` kube-prometheus-stack 93.10.1（`--kube-version 1.37.0`）+ 两个 values 文件：渲染成功，Alertmanager 的 `spec.secrets` 有 `alertmanager-robots`，三个 webhook 都是 `url_file`。`kubectl kustomize prometheusalert/`：生成 ConfigMap、Service、Deployment。
- 完整告警链路（Docker 模拟）：mall-api（`MALL_DEBUG=true`）→ Prometheus v3.16.0（静态抓取，标签 `job=mall-api`、`namespace=mall`，加载本目录两个规则文件）→ Alertmanager v0.35.1（本目录的路由和抑制配置，`url_file` 挂载方式与 K8s 一致）→ PrometheusAlert v5.0.0（`PA_` 环境变量、`/template/import` 导入 `ops-mall-templates.json`）→ 模拟的企业微信 webhook 端点（记录收到的报文）。`fire-drill.sh error` 跑起来后：约 1 分钟 Pending，约 3 分钟 critical Firing，10 秒后两个 P1 webhook 都收到【告警 P1 紧急】；warning 在约 6 分钟 Firing 后被 critical 抑制（Alertmanager 状态 suppressed），运维群没有收到；停止演练约 5.5 分钟后恢复，下一个 group_interval 收到【已恢复】，时间显示为北京时间。
- `exporters/install-exporters.sh node` 在 Ubuntu 24.04（systemd 容器，ufw 已启用）上执行通过：sha256 校验 OK、systemd 服务 active、`ufw status` 里有 9100 的放行规则、系统用户 shell 为 `/usr/sbin/nologin`。

没验证 / 与教程不同的地方：
- **真实企业微信群推送没有做**：验证环境的工具策略不允许读取讲师本机保存测试 webhook 的文件，所以 PrometheusAlert 发往的是模拟端点。报文格式与企业微信群机器人接口一致，PrometheusAlert 收到了模拟端点返回的 `errcode 0`。讲师可以用 `test-payload.json` 手工发一条（教程 5.10.2 的 curl）确认真实群的显示效果。
- 验证环境没有 MySQL，`/api/products` 也返回 500，所以实测错误率是 100%，不是教程里的约 33%；教程里消息示例的百分比按课程环境写。
- K8s 里的部署（Helm 安装、ServiceMonitor、ScrapeConfig、HTTPRoute、Grafana sidecar 导入大盘、PrometheusAlert 的 `postStart` 自动导入）没有在集群上跑，K8s 集群验证由讲师另行安排。
- mysqld_exporter、redis_exporter 的安装、钉钉渠道（`type=dd`）没有验证。

