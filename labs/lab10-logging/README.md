# Lab 10 企业日志收集方案：实验代码

对应教程：《DevOps 运维实战》→ DevOps 核心实验 → Lab 10 企业日志收集方案。

主线是 **Fluent Bit + Loki + Grafana**（轻量，实验环境推荐）；**EFK（Elasticsearch + Kibana）** 做精简版选做，对比两种方案的资源占用和使用体验。

## 文件清单

| 文件 | 用途 | 在哪执行 |
|---|---|---|
| `loki/loki-values.yaml` | Loki 单体模式：文件系统存储、多租户（mall / platform）、按租户保留（14 天 / 3 天）、ruler 接 Alertmanager、关掉 8GiB 的 chunks 缓存 | k8s-master |
| `loki/httproute-loki-push.yaml` | 只暴露写入接口 `loki.lab.local/loki/api/v1/push`，给虚拟机上的 Fluent Bit 用 | k8s-master |
| `loki/grafana-datasource-loki.yaml` | 给 Lab 09 的 Grafana 加 Loki-mall、Loki-platform 两个数据源（sidecar 自动导入），request_id 可点击跳转 | k8s-master |
| `fluent-bit/fluent-bit-values.yaml` | Fluent Bit DaemonSet：采集容器日志、解析 mall-api JSON、按 namespace/app 打标签、按命名空间分租户写 Loki | k8s-master |
| `fluent-bit/fluent-bit-values-efk.yaml` | 选做：在 Loki 之外再写一份到 Elasticsearch（叠加在上一个文件之后） | k8s-master |
| `vm/nginx-mall-log.conf` | Nginx JSON 访问日志格式 + request_id 透传给 mall-api | lab-web1、lab-web2 |
| `vm/mysql-slow-log.sql` | 用 `SET PERSIST` 打开慢查询日志（不用重启 MySQL） | lab-db1 |
| `vm/parsers-vm.conf` | 虚拟机用的 JSON 解析器和 MySQL 慢日志多行解析器 | lab-web1/2、lab-db1 |
| `vm/fluent-bit-web.conf` | web 机器：Nginx 访问 / 错误日志 + mall-api 的 journald 日志 | lab-web1、lab-web2 |
| `vm/fluent-bit-db.conf` | db 机器：MySQL 慢日志 + 错误日志 | lab-db1 |
| `vm/install-fluent-bit-vm.sh` | Ubuntu 24.04：加 Fluent Bit 官方 apt 源（DEB822 + GPG 签名）、安装、写配置、语法检查后重启 | lab-web1/2、lab-db1 |
| `rules/loki-alert-rules.yaml` | 日志告警：ERROR 日志突增、慢请求、Nginx 5xx、MySQL 慢查询突增、MySQL 错误日志 | k8s-master |
| `efk/eck-operator-values.yaml` | 选做：ECK Operator | k8s-master |
| `efk/elasticsearch.yaml`、`efk/kibana.yaml` | 选做：单节点 Elasticsearch（2Gi）和 Kibana（1Gi） | k8s-master |
| `efk/httproute-kibana.yaml` | 选做：Gateway API 暴露 `kibana.lab.local` | k8s-master |
| `efk/setup-es.sh` | 选做：ILM 7 天删除、索引模板、fluentbit 只写账号、Kibana 空间 + 只读角色 + 数据视图 | k8s-master |

## 写作时版本

| 组件 | 版本 |
|---|---|
| Loki Helm chart（grafana-community/loki） | 21.6.0（Loki 3.7.10） |
| Fluent Bit Helm chart（fluent/fluent-bit） | 0.58.3（Fluent Bit 5.1.3） |
| 虚拟机上的 Fluent Bit（Ubuntu 24.04，官方 apt 源） | 5.2.1 |
| ECK Operator / Elasticsearch / Kibana | 3.5.0 / 9.5.7 / 9.5.7 |

2026 年 3 月起 Loki 的 Helm chart 改由 grafana-community 仓库维护，版本号重新编排，单体模式改名为 `Monolithic`。以官方最新文档为准。

## 快速开始（Loki 主线）

前提：Lab 09 的 kube-prometheus-stack 已安装；集群有默认 StorageClass（Lab 09 装的 local-path）。

```bash
# k8s-master
helm upgrade --install loki oci://ghcr.io/grafana-community/helm-charts/loki \
  --version 21.6.0 -n logging --create-namespace -f loki/loki-values.yaml
helm upgrade --install fluent-bit oci://ghcr.io/fluent/helm-charts/fluent-bit \
  --version 0.58.3 -n logging -f fluent-bit/fluent-bit-values.yaml
kubectl apply -f loki/httproute-loki-push.yaml -f loki/grafana-datasource-loki.yaml -f rules/loki-alert-rules.yaml
```

```bash
# lab-web1、lab-web2（root，先按教程改好 Nginx 配置）
./install-fluent-bit-vm.sh web
# lab-db1（root，先执行 mysql-slow-log.sql）
./install-fluent-bit-vm.sh db
```

## 需要按实际环境修改的地方

- 三个 HTTPRoute 的 `parentRefs` 假设 Lab 06 的 Gateway 叫 `lab-gateway`、在 `envoy-gateway-system` 命名空间。
- `loki.lab.local` 指向 K8s 网关入口（课程约定的域名表），虚拟机 hosts 里要加 `192.168.56.200 loki.lab.local`。
- `vm/fluent-bit-web.conf` 假设 Lab 02 里 mall-api 的 systemd 服务名是 `mall-api.service`。
- `vm/fluent-bit-db.conf` 假设 MySQL 错误日志在 `/var/log/mysql/error.log`、慢日志在 `/var/log/mysql/mysql-slow.log`（Ubuntu 24.04 上 MySQL 的默认日志目录，配置文件在 `/etc/mysql/mysql.conf.d/`）。Lab 02 改过日志路径的，以 `SELECT @@log_error, @@slow_query_log_file;` 的结果为准，同时改 `mysql-slow-log.sql` 和 `fluent-bit-db.conf`。
## 验证记录
写作时在一台 Ubuntu 24.04 实验机上用 Docker 做了验证（不是 K8s 集群）：Loki 3.7.10 单个容器（配置对应 `loki/loki-values.yaml` 的多租户、tsdb v13、filesystem、保留和 ruler 部分，监听 80 端口，`loki.lab.local` 用 hosts 指过去），两个带 systemd 的 Ubuntu 24.04 容器分别扮演 lab-web1 和 lab-db1。

已验证：
- lab-web1：按教程 5.6.2 放 `nginx-mall-log.conf`、改 `/etc/nginx/conf.d/mall.conf`（Ubuntu 自带 nginx 1.24.0），`nginx -t` 通过；响应头的 `X-Request-Id` 和 `/var/log/nginx/mall_access_json.log` 里的 `request_id` 一致，请求头自带的 ID 会原样透传到 mall-api 的 journald 日志；`/etc/logrotate.d/nginx` 匹配 `/var/log/nginx/*.log`。
- lab-db1：Ubuntu 24.04 自带的 MySQL 8.0.46，`mysql-slow-log.sql` 执行后慢日志写到 `/var/log/mysql/mysql-slow.log`，重启 MySQL 后 `@@slow_query_log_file` 仍然是这个路径（SET PERSIST 生效）；错误日志是 `/var/log/mysql/error.log`；`/etc/logrotate.d/mysql-server` 匹配 `/var/log/mysql/*log`。
- `install-fluent-bit-vm.sh web` 和 `db` 都执行通过：探测 Loki 返回 422、加 `packages.fluentbit.io/ubuntu/noble` 源、装上 Fluent Bit v5.2.1、`--dry-run` 通过、服务 active；输出计数 errors 为 0。
- 用 `fire-drill.sh error`、`fire-drill.sh slow` 造流量后，在租户 `mall` 下跑了教程里的 LogQL（K8s 的选择器 `{namespace="mall", app="mall-api"}` 换成虚拟机上的 `{job="mall-api-vm"}`，管道部分不变）：按 request_id 同时查到 Nginx 和 mall-api 两条日志、`| json | request_id=`、按 route 统计 5xx、按 status 统计 Nginx、`duration_ms > 1000` + `line_format`、`quantile_over_time ... unwrap duration_ms`、Nginx `request_time > 1`、MySQL 慢日志 `regexp` 提取 `query_time` 和 `rows_examined`，结果都符合预期；`{job="mysql-slow"}` 每条是完整的多行记录。
- Loki ruler 加载了 `rules/loki-alert-rules.yaml` 里的 5 条规则（health 都是 ok），`NginxHigh5xx` 在 error 演练后 firing，经 Alertmanager → PrometheusAlert（Lab 09）送到了模拟的企业微信端点，消息里带“来源：loki”。

没验证：
- K8s 里的部分（Loki / Fluent Bit 的 Helm 安装、DaemonSet 采集容器日志、HTTPRoute、Grafana 数据源、rules sidecar、EFK 选做）没有在集群上跑，只做了 `helm template --kube-version 1.37.0` 渲染检查（loki 21.6.0、fluent-bit 0.58.3 都能正常渲染），K8s 集群验证由讲师另行安排。
- MySQL 慢日志的第一条记录会把 MySQL 重启时写进慢日志的文件头（`/usr/sbin/mysqld, Version: ... started with:`）也拼进去，这是多行解析规则的预期行为，不影响查询。
- Lab 02 的 Ubuntu 版如果装的是 MySQL 8.4（官方源），日志目录同样是 `/var/log/mysql/`，但没有实测。

