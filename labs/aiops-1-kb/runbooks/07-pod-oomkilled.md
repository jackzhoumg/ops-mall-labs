---
title: Pod OOMKilled 排查
tags: kubernetes, oom, memory, limit, leak
owner: 运维组
updated: 2026-09-02
---
# Pod OOMKilled 排查

## 1. 现象
- 告警 `MallPodOOMKilled`：容器最近一次退出原因是 `OOMKilled`。
- `kubectl describe pod` 里 `Last State: Terminated, Reason: OOMKilled, Exit Code: 137`。

OOMKilled 是容器内存用量超过了 `resources.limits.memory`，被 Linux 内核 cgroup 的 OOM killer 杀掉。和"节点内存不足导致 Pod 被驱逐（Evicted）"是两回事。

## 2. 判断是泄漏还是 limit 太小
Prometheus 查最近 6 小时的内存曲线：
```promql
max by (pod) (container_memory_working_set_bytes{namespace="mall", container="mall-api"})
```
- **持续上涨、从不回落，到 limit 就被杀，重启后又从头涨**：内存泄漏。mall-api 的 `/api/debug/leak` 演练就是这个曲线。
- **平时平稳，某个时刻突然冲高**：瞬时大请求（比如一次查出大量数据）或者流量突增，limit 留的余量不够。
- Go 程序还可以看 `go_memstats_heap_inuse_bytes` 和 `go_goroutines`，goroutine 数一直涨通常是 goroutine 泄漏。

## 3. 排查命令
在 k8s-master 上执行：
```bash
kubectl -n mall describe pod <pod名> | grep -A5 'Last State'
kubectl -n mall get pod <pod名> -o jsonpath='{.spec.containers[0].resources}'; echo
kubectl -n mall top pod -l app.kubernetes.io/name=mall-api
# 有没有人在调泄漏接口
kubectl -n mall logs <pod名> --previous | grep '/api/debug/leak' | tail
```

## 4. 处理
- 泄漏：临时措施是加副本、适当调大 limit 争取时间，同时让开发用 pprof 定位；不要只调大 limit 了事，泄漏会在更大的 limit 处再次触发。
- limit 太小：按 P99 内存用量 × 1.3 左右重新设置 limit，requests 设成平时用量。mall-api 默认 requests 64Mi、limits 256Mi。
- 改资源配置走 Helm values 和 GitOps，不要直接 `kubectl edit`。

## 5. 预防
- 内存告警分两档：工作集超过 limit 的 80% 提前预警，OOMKilled 事后告警。
- 发布后观察 30 分钟内存曲线，压测时要跑够时长（至少 1 小时）才能发现慢泄漏。
- Go 1.19 以后可以设置 `GOMEMLIMIT`（比如 limit 的 90%），让 GC 在接近上限时更积极回收。
