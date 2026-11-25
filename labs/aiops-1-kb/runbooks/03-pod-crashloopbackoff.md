---
title: Pod CrashLoopBackOff 排查
tags: kubernetes, crashloopbackoff, pod, mall-api
owner: 运维组
updated: 2026-10-30
---
# Pod CrashLoopBackOff 排查

## 1. 现象
- 告警 `MallPodCrashLooping`：`mall` 命名空间的 mall-api Pod 处于 `CrashLoopBackOff` 超过 5 分钟。
- `kubectl get pod` 看到 RESTARTS 一直在涨，STATUS 在 `Running`、`Error`、`CrashLoopBackOff` 之间切换。

CrashLoopBackOff 不是一种错误，而是 kubelet 的状态：容器反复退出，kubelet 每次重启前等待的时间越来越长（10 秒起，翻倍，最长 5 分钟）。要找的是"容器为什么退出"。

## 2. 三条命令定位原因
在 k8s-master 上执行：
```bash
# 1) 上一次退出的原因和退出码
kubectl -n mall describe pod <pod名> | sed -n '/Last State/,/Ready/p'
# 2) 上一次运行（已经退出的那个容器）的日志
kubectl -n mall logs <pod名> --previous --tail=100
# 3) 事件
kubectl -n mall get events --field-selector involvedObject.name=<pod名> --sort-by=.lastTimestamp
```

## 3. 按退出原因处理
| Last State | 退出码 | 常见原因 | 处理 |
|---|---|---|---|
| `Error` | 1 | 程序启动就报错退出：配置错、连不上依赖 | 看 `--previous` 日志 |
| `OOMKilled` | 137 | 超过内存 limit 被内核杀掉 | 转《Pod OOMKilled 排查》 |
| `Completed` | 0 | 程序正常退出了，但 Deployment 要求一直运行 | 检查启动命令是不是写成了一次性任务 |
| `Error` | 137 且不是 OOM | livenessProbe 连续失败被 kubelet 杀掉 | 看事件里的 `Liveness probe failed` |

## 4. mall-api 的典型案例
- **日志里有 `invalid DSN` 或 `Access denied for user 'mall'`**：`MALL_DB_DSN` 配错，或者 Secret 里的密码改了没同步。检查：
  ```bash
  kubectl -n mall get deploy mall-api -o jsonpath='{.spec.template.spec.containers[0].envFrom}'
  kubectl -n mall get secret mall-api-secret -o jsonpath='{.data}' | head -c 200; echo
  ```
  注意：mall-api 连不上数据库时**不会退出**，`/readyz` 返回 503、Pod 变成 NotReady；如果它在退出，说明是启动参数本身有问题。
- **livenessProbe 指向了 `/readyz`**：数据库抖一下，所有 Pod 被一起重启，雪崩。liveness 必须用 `/healthz`（只看进程），readiness 用 `/readyz`。
- **镜像 tag 写错或架构不对**：Pod 状态是 `ImagePullBackOff` 或日志里出现 `exec format error`（amd64 镜像跑在 arm64 节点上）。

## 5. 恢复
- 刚发布引起的：先回滚 `kubectl -n mall rollout undo deploy/mall-api`，再查。
- 需要进入容器调试但容器起不来：`kubectl -n mall debug <pod名> -it --image=busybox:1.37 --target=mall-api`。

## 6. 预防
- 发布流水线里加 smoke test：新版本 Pod Ready 后请求 `/readyz` 和 `/api/products`。
- 配置和密钥变更也走 Git 和 ArgoCD，不要在集群里直接 `kubectl edit`。
