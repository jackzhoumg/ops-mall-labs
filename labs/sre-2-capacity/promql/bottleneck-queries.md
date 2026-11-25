# 压测时逐层定位瓶颈的 PromQL

压测时把这些查询放进 Grafana 的一个临时大盘，或者直接在 Prometheus 页面执行。
从外到内一层层看：**哪一层先“饱和”（排队、限流、资源到顶），瓶颈就在哪一层**。

指标来源：

| 层 | 指标来源 | 前提 |
|---|---|---|
| 网关 | Envoy 代理 `:19001/stats/prometheus` | 用 `k8s/envoy-podmonitor.yaml` 让 Prometheus 抓取 |
| mall-api | `app/metrics.go` 暴露的 `mall_*`、Go 运行时指标 | Lab 09 的 ServiceMonitor |
| 容器 | kubelet / cAdvisor（`container_*`） | kube-prometheus-stack 默认就有 |
| MySQL | mysqld_exporter（`mysql_*`） | Lab 09 在 lab-db1 上装的 exporter |
| Redis | redis_exporter（`redis_*`） | Lab 09 在 lab-db1 上装的 exporter |
| 主机 | node_exporter（`node_*`） | kube-prometheus-stack 默认就有 |

标签名（`job`、`namespace`、`pod`、`instance`）按你的实际抓取配置调整。Lab 09 的 ServiceMonitor 同时抓 mall、mall-staging、mall-prod，job 都叫 `mall-api`，所以 mall-api 的查询都带 `namespace="mall"`。
lab-db1 上的 exporter 由 Lab 09 的 ScrapeConfig 抓取（job 名 `vm-mysql`、`vm-redis`、`vm-node`）。

## 0. 压测机自己

k6 输出里 `dropped_iterations` 大于 0、或者压测机 CPU 超过 80%：压测机先成了瓶颈，结果不可信。换一台更强的机器或者多台分布式压。

## 1. 网关（Envoy）

```promql
# 网关收到的总 RPS
sum(rate(envoy_http_downstream_rq_total[1m]))

# 网关看到的上游（mall-api）响应时间 P99，单位毫秒
histogram_quantile(0.99, sum by (le) (rate(envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name=~".*mall.*"}[1m])))

# 上游 5xx
sum(rate(envoy_cluster_upstream_rq_xx{envoy_cluster_name=~".*mall.*",envoy_response_code_class="5"}[1m]))

# 排队中的请求、因熔断阈值被拒绝的请求（大于 0 说明网关在限流，出现 503 + UO 标记）
sum(envoy_cluster_upstream_rq_pending_active{envoy_cluster_name=~".*mall.*"})
sum(rate(envoy_cluster_upstream_rq_pending_overflow{envoy_cluster_name=~".*mall.*"}[1m]))

# Envoy 容器 CPU
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="envoy-gateway-system",container="envoy"}[1m]))
```

判断：网关 P99 ≈ mall-api 自己的 P99，说明时间花在后面；网关 P99 明显更大，查 Envoy CPU、连接数、熔断。

## 2. mall-api

```promql
# 各路由 RPS 和 P99（和 SRE-1 的 SLO 对应）
sum by (route) (rate(mall_http_requests_total{job="mall-api",namespace="mall"}[1m]))
histogram_quantile(0.99, sum by (le, route) (rate(mall_http_request_duration_seconds_bucket{job="mall-api",namespace="mall"}[1m])))

# 5xx 比例
sum(rate(mall_http_requests_total{job="mall-api",namespace="mall",status=~"5.."}[1m])) / sum(rate(mall_http_requests_total{job="mall-api",namespace="mall"}[1m]))

# 正在处理的请求数（并发）。按利特尔法则：并发 ≈ RPS × 平均耗时
sum by (pod) (mall_http_inflight_requests{job="mall-api",namespace="mall"})

# 每个 Pod 的 CPU 使用和 requests 的比例（HPA 看的就是这个）
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="mall",container="mall-api"}[1m]))
  / sum by (pod) (kube_pod_container_resource_requests{namespace="mall",container="mall-api",resource="cpu"})

# CPU 被限流的比例（limits 太小的信号：CPU 用量没到 limit 但延迟变高）
sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="mall",container="mall-api"}[1m]))
  / sum by (pod) (rate(container_cpu_cfs_periods_total{namespace="mall",container="mall-api"}[1m]))

# 内存、goroutine（持续上涨不回落 = 泄漏，稳定性压测重点看）
sum by (pod) (container_memory_working_set_bytes{namespace="mall",container="mall-api"})
sum by (pod) (go_goroutines{job="mall-api",namespace="mall"})

# 缓存命中率
rate(mall_cache_hits_total{job="mall-api",namespace="mall"}[1m]) / (rate(mall_cache_hits_total{job="mall-api",namespace="mall"}[1m]) + rate(mall_cache_misses_total{job="mall-api",namespace="mall"}[1m]))
```

判断：

- CPU 到 requests 的 100% 以上、限流比例高 → 应用 CPU 瓶颈，扩容或调大 requests/limits
- CPU 不高但 P99 涨、inflight 堆积 → 在等下游（数据库连接池、行锁、Redis），往下查
- mall-api 的数据库连接池上限是 20（`store.go` 里 `SetMaxOpenConns(20)`），连接池用满时请求在应用里排队，表现就是“CPU 不高、延迟很高”

## 3. MySQL（lab-db1）

```promql
# 连接数和上限（Pod 数 × 20 不能超过 max_connections）
mysql_global_status_threads_connected
mysql_global_variables_max_connections

# 正在执行的线程（持续 > CPU 核数 说明数据库忙不过来）
mysql_global_status_threads_running

# QPS、慢查询
rate(mysql_global_status_questions[1m])
rate(mysql_global_status_slow_queries[1m])

# 行锁等待：下单接口 SELECT ... FOR UPDATE 抢同一行时会涨
rate(mysql_global_status_innodb_row_lock_waits[1m])
rate(mysql_global_status_innodb_row_lock_time[1m])

# 主机 CPU、磁盘 IO 利用率
1 - avg(rate(node_cpu_seconds_total{instance=~"192.168.56.13.*",mode="idle"}[1m]))
rate(node_disk_io_time_seconds_total{instance=~"192.168.56.13.*"}[1m])
```

数据库上还可以直接看：

```sql
SHOW PROCESSLIST;                                   -- 大量 Waiting for ... lock 说明锁竞争
SELECT * FROM sys.innodb_lock_waits\G               -- 谁在等谁的锁
SELECT * FROM sys.statements_with_runtimes_in_95th_percentile LIMIT 10;  -- 最慢的 SQL
```

## 4. Redis（lab-db1）

```promql
rate(redis_commands_processed_total[1m])
redis_connected_clients
redis_memory_used_bytes
# Redis 是单线程，单核 CPU 打满就是瓶颈
rate(redis_cpu_user_seconds_total[1m]) + rate(redis_cpu_sys_seconds_total[1m])
```

## 5. 节点

```promql
# 每个节点的 CPU 使用率
1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m]))

# 节点上 Pod requests 的总和占可分配 CPU 的比例（> 90% 新 Pod 就调度不上去，HPA 扩出来是 Pending）
sum by (node) (kube_pod_container_resource_requests{resource="cpu"}) / sum by (node) (kube_node_status_allocatable{resource="cpu"})
```
