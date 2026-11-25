#!/usr/bin/env bash
# AIOps-2：不等真实告警，直接把示例 webhook 发给 alert-analyzer，验证 采集 → 大模型 → 推送 整条链路。
# 用法（k8s-master）：
#   bash scripts/send-test-alert.sh              # 自动 port-forward 到 svc/alert-analyzer
#   URL=http://127.0.0.1:8080 bash scripts/send-test-alert.sh   # 本地直接跑服务时
# 同一告警 30 分钟内只分析一次。重复测试前先发一条恢复消息清掉冷却：
#   bash scripts/send-test-alert.sh resolve
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
payload="$here/test-payload.json"
mode="${1:-fire}"
pf_pid=""

cleanup() {
  if [[ -n "$pf_pid" ]]; then
    kill "$pf_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ -z "${URL:-}" ]]; then
  kubectl -n monitoring port-forward svc/alert-analyzer 18080:8080 >/dev/null 2>&1 &
  pf_pid=$!
  URL="http://127.0.0.1:18080"
  for _ in $(seq 20); do
    curl -fs "$URL/healthz" >/dev/null 2>&1 && break
    sleep 0.5
  done
fi

body="$(cat "$payload")"
if [[ "$mode" == "resolve" ]]; then
  # 把所有告警状态改成 resolved
  body="$(sed 's/"status": "firing"/"status": "resolved"/g' "$payload")"
fi

echo "POST $URL/alertmanager ($mode)"
curl -fsS -X POST "$URL/alertmanager" -H 'Content-Type: application/json' --data-binary "$body"
echo
echo "分析在后台进行，10-40 秒后看结果："
echo "  kubectl -n monitoring logs deploy/alert-analyzer --tail=20 | grep -E 'analyzed|dry_run|llm_'"
