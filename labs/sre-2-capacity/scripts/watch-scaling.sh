#!/usr/bin/env bash
# 压测时盯着扩缩容：每 10 秒打印一次 HPA 状态、Pod 数、每个 Pod 的 CPU / 内存。
#
# 用法（k8s-master）：
#   bash scripts/watch-scaling.sh
#   NS=mall APP=mall-api INTERVAL=5 bash scripts/watch-scaling.sh
set -uo pipefail

NS="${NS:-mall}"
APP="${APP:-mall-api}"
INTERVAL="${INTERVAL:-10}"

while true; do
  echo "================ $(date '+%T') ================"
  kubectl -n "$NS" get hpa 2>/dev/null || echo "（没有 HPA）"
  echo
  kubectl -n "$NS" get pod -l "app.kubernetes.io/name=${APP}" \
    -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready --no-headers
  echo
  kubectl -n "$NS" top pod -l "app.kubernetes.io/name=${APP}" --no-headers 2>/dev/null \
    || echo "kubectl top 失败：metrics-server 还没就绪"
  sleep "$INTERVAL"
done
