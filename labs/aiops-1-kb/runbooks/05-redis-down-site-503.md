---
title: Redis 不可用导致全站 503
tags: redis, cache, readyz, 503, mall-api
owner: 运维组
updated: 2026-10-05
---
# Redis 不可用导致全站 503

## 1. 现象
- 商城所有接口返回 503，网关日志 `no healthy upstream`。
- `kubectl -n mall get pod` 看到 mall-api 都是 `0/1 Running`（NotReady），但没有重启。
- 告警 `RedisDown`（lab-db1 192.168.56.13:6379）和 `MallApiDown` 先后出现。

## 2. 为什么 Redis 挂了整个站都不可用
mall-api 配置了 `MALL_REDIS_ADDR` 时，`/readyz` 会同时检查 MySQL 和 Redis，任何一个不通就返回 503。
readinessProbe 用的是 `/readyz`，所以 Redis 一挂，所有 Pod 同时被摘掉，流量无处可去。
而 mall-api 的业务代码其实能容忍缓存失败：读缓存出错会打一条 `cache get failed, fallback to db` 的警告日志，直接查数据库。

## 3. 确认
```bash
# 在 k8s-master：看 readyz 的详细结果
kubectl -n mall exec deploy/mall-api -- wget -qO- http://127.0.0.1:8080/readyz
# 预期看到 {"checks":{"mysql":"ok","redis":"dial tcp ...: connect: connection refused"},"ready":false}

# 在 lab-db1：Redis 状态
systemctl status redis --no-pager
redis-cli -a '<密码>' ping
sudo tail -n 50 /var/log/redis/redis.log
```
mall-api 镜像是精简镜像，可能没有 wget，这时用 `kubectl -n mall port-forward deploy/mall-api 8080:8080` 后在本机 curl。

## 4. 止血（先恢复业务）
二选一：
1. **尽快拉起 Redis**：`sudo systemctl restart redis`。常见启动失败原因：内存不足被 OOM、`/var/lib/redis` 磁盘满、RDB 文件损坏。
2. **临时关掉缓存**：去掉 `MALL_REDIS_ADDR`，mall-api 只查数据库，`/readyz` 不再检查 Redis：
   ```bash
   kubectl -n mall set env deploy/mall-api MALL_REDIS_ADDR-
   ```
   注意：流量大时所有请求直接打到 MySQL，要盯住 MySQL 的连接数和 CPU。用 GitOps 管理的环境，事后要把改动补到 Git，否则 ArgoCD 会改回去。

## 5. 恢复后检查
```bash
curl -sI http://mall.lab.local/api/products | grep -i x-cache   # 第一次 MISS，30 秒内再请求应该是 HIT
```
Grafana 看 `mall_cache_hits_total` / `mall_cache_misses_total` 的比例是否恢复。

## 6. 根因与改进
- 缓存是"可降级依赖"，不应该放进 readiness 检查；这是一个设计问题，已提需求给开发：readyz 只检查 MySQL，Redis 失败只告警。
- Redis 单点：评估主从 + Sentinel，或者云上托管 Redis。
- 给 Redis 配 `maxmemory` 和淘汰策略 `allkeys-lru`，避免内存打满被系统 OOM。
