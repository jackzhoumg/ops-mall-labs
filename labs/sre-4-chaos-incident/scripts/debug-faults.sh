#!/usr/bin/env bash
# debug-faults.sh：调用 mall-api 自带的故障接口（需要 MALL_DEBUG=true），制造应用层故障。
# 对应教程：SRE-4 故障演练与事故管理
#
# 用法（在能访问 mall.lab.local 的机器上执行）：
#   bash debug-faults.sh slow 3000 20     # 并发 20 个慢请求，每个 3000ms
#   bash debug-faults.sh error 50         # 50 次 500 错误，用来触发错误率告警
#   bash debug-faults.sh cpu 60           # 让某个 Pod 占满 CPU 60 秒
#   bash debug-faults.sh leak 100 5       # 每次泄漏 100MB，调 5 次，看 OOMKilled
#
# 请求经过网关会负载均衡到不同 Pod。想知道落在哪个 Pod：curl http://mall.lab.local/api/version 看 hostname。
set -euo pipefail

BASE="${BASE:-http://mall.lab.local}"
action="${1:-}"

case "$action" in
  slow)
    ms="${2:-2000}"
    n="${3:-10}"
    for _ in $(seq "$n"); do
      curl -s -o /dev/null -w "slow ${ms}ms -> %{http_code} %{time_total}s\n" "$BASE/api/debug/slow?ms=$ms" &
    done
    wait
    ;;
  error)
    n="${2:-20}"
    for _ in $(seq "$n"); do
      curl -s -o /dev/null -w "error -> %{http_code}\n" "$BASE/api/debug/error"
    done
    ;;
  cpu)
    secs="${2:-30}"
    curl -s -m $((secs + 10)) "$BASE/api/debug/cpu?seconds=$secs"
    echo
    ;;
  leak)
    mb="${2:-50}"
    n="${3:-1}"
    for _ in $(seq "$n"); do
      curl -s "$BASE/api/debug/leak?mb=$mb"
      echo
    done
    ;;
  *)
    echo "用法：$0 {slow <ms> <次数>|error <次数>|cpu <秒>|leak <mb> <次数>}" >&2
    exit 2
    ;;
esac
