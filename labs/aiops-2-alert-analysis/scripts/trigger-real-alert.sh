#!/usr/bin/env bash
# AIOps-2：用 mall-api 的 /api/debug/error 制造真实的 5xx，等 Prometheus 规则触发 MallApiHighErrorRate，
# 走一遍 Prometheus → Alertmanager → alert-analyzer → 群 的完整链路。
#
# 前提：mall 命名空间的 mall-api 开了 MALL_DEBUG=true
#   kubectl -n mall set env deploy/mall-api MALL_DEBUG=true
# 用法（能解析 mall.lab.local 的机器）：
#   bash scripts/trigger-real-alert.sh          # 默认持续 9 分钟
#   DURATION=600 BASE_URL=http://192.168.56.200 bash scripts/trigger-real-alert.sh
# 为什么要 9 分钟：warning 级规则要求 5 分钟错误率 > 1% 且持续 for: 5m，再加上 Alertmanager group_wait。
# 实验结束后记得关掉：kubectl -n mall set env deploy/mall-api MALL_DEBUG=false
set -euo pipefail

BASE_URL="${BASE_URL:-http://mall.lab.local}"
DURATION="${DURATION:-540}"

code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$BASE_URL/api/debug/error" || echo 000)"
if [[ "$code" == "404" ]]; then
  echo "/api/debug/error 返回 404：先执行 kubectl -n mall set env deploy/mall-api MALL_DEBUG=true" >&2
  exit 1
fi
if [[ "$code" == "000" ]]; then
  echo "访问不到 ${BASE_URL}，检查 hosts 或用 BASE_URL=http://<网关IP>" >&2
  exit 1
fi

echo "开始制造错误流量：${DURATION}s，约 20% 请求返回 500（${BASE_URL}）"
end=$((SECONDS + DURATION))
n=0
errors=0
while ((SECONDS < end)); do
  for _ in 1 2 3 4; do
    curl -s -o /dev/null -m 5 "$BASE_URL/api/products" || true
  done
  c="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$BASE_URL/api/debug/error" || echo 000)"
  [[ "$c" == "500" ]] && errors=$((errors + 1))
  n=$((n + 5))
  if ((n % 500 == 0)); then
    echo "已发送 $n 个请求，其中 500 错误 $errors 个，剩余 $((end - SECONDS))s"
  fi
  sleep 0.3
done
echo "完成：共 $n 个请求，500 错误 $errors 个。到 Alertmanager 界面或群里看告警和 AI 分析。"
