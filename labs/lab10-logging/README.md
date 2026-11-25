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
| `vm/install-fluent-bit-vm.sh` | 装 Fluent Bit 官方包、写配置、语法检查后重启 | lab-web1/2、lab-db1 |
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
- `loki.lab.local` 是本实验新增的域名（课程约定的域名表里没有），虚拟机 hosts 里要加 `192.168.56.200 loki.lab.local`。
- `vm/fluent-bit-web.conf` 假设 Lab 02 里 mall-api 的 systemd 服务名是 `mall-api.service`。
- `vm/fluent-bit-db.conf` 假设 MySQL 错误日志在 `/var/log/mysql/mysqld.log`（Rocky Linux 9 自带 mysql-server 的默认位置），用 MySQL 官方仓库安装的在 `/var/log/mysqld.log`。
