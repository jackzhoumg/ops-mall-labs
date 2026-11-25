---
title: mall-api 接口延迟高排查
tags: latency, p99, prometheus, mysql, slow query
owner: 运维组
updated: 2026-10-20
---
# mall-api 接口延迟高排查

## 1. 现象
- 告警 `MallApiHighLatency`：P99 超过 2 秒（critical）或 P95 超过 500ms（warning）。
- 用户反馈页面转圈，下单慢。

## 2. 先找出是哪个接口慢
在 Grafana 或 Prometheus 里执行：
```promql
histogram_quantile(0.99, sum by (route, le) (rate(mall_http_request_duration_seconds_bucket{namespace="mall"}[5m])))
```
- 只有 `POST /api/orders` 慢：下单要开事务、`SELECT ... FOR UPDATE` 锁商品行，看第 4 节数据库锁。
- 只有 `GET /api/products` 慢：缓存可能失效了，看 `X-Cache` 是不是一直 MISS，以及 `mall_cache_misses_total` 的增长。
- 所有接口都慢：看实例资源（CPU 限流）和数据库整体状态。
- 有 `GET /api/debug/slow`：有人在做故障演练，先在群里确认。

## 3. 看实例资源
```bash
kubectl -n mall top pod -l app.kubernetes.io/name=mall-api
```
Prometheus 查 CPU 被限流（throttling）的比例：
```promql
sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="mall", container="mall-api"}[5m]))
  /
sum by (pod) (rate(container_cpu_cfs_periods_total{namespace="mall", container="mall-api"}[5m]))
```
超过 25% 说明 CPU limit 太小，或者有接口在吃 CPU（`/api/debug/cpu` 演练也会这样）。处理：临时扩副本 `kubectl -n mall scale deploy/mall-api --replicas=4`。

## 4. 看数据库
在 lab-db1 上执行：
```bash
mysql -uroot -p -e "SHOW FULL PROCESSLIST;" | grep -v Sleep | head -30
mysql -uroot -p -e "SELECT * FROM sys.innodb_lock_waits\G" | head -40
```
- 大量 `Waiting for ... lock`：有长事务锁住了商品行，找到 `blocking_pid` 对应的会话，确认后 `KILL <id>`。
- 有执行时间很长的 SELECT：打开慢查询日志 `slow_query_log=ON`、`long_query_time=0.5`，用 `pt-query-digest` 汇总。
- mall-api 连接池上限是 20（代码里 `SetMaxOpenConns(20)`），副本数 × 20 不能超过 MySQL 的 `max_connections`。

## 5. 看请求链路
用访问日志的 `duration_ms` 字段找出最慢的请求，再用 `request_id` 追踪：
```logql
{namespace="mall", container="mall-api"} | json | msg="access" | duration_ms > 1000
```

## 6. 恢复与预防
- 定位到发布引起的：回滚。
- 定位到数据库：慢 SQL 加索引、大事务拆分；大促前做容量评估和压测。
- 告警阈值和 SLO 对齐：P99 2 秒是"用户明显感觉卡"的线，P95 500ms 是"要关注"的线。
