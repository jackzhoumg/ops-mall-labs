#!/usr/bin/env bash
# 连续请求 /api/version，统计每个版本各占多少，观察金丝雀流量比例
# 在学员电脑或任意一台能访问网关的机器上执行：
#   bash labs/lab08-gitops/rollouts/watch-version.sh                 # 默认 mall-prod.lab.local，100 次
#   HOST=mall-staging.lab.local COUNT=50 bash labs/lab08-gitops/rollouts/watch-version.sh
#   WATCH=1 bash labs/lab08-gitops/rollouts/watch-version.sh         # 每 5 秒统计一轮，Ctrl+C 退出
set -euo pipefail

HOST="${HOST:-mall-prod.lab.local}"
COUNT="${COUNT:-100}"
WATCH="${WATCH:-0}"

one_round() {
  local i out
  out="$(mktemp)"
  for ((i = 1; i <= COUNT; i++)); do
    # 用 X-Request-ID 方便在日志里定位这批测试请求
    curl -s --max-time 2 -H "X-Request-ID: canary-check-$i" "http://${HOST}/api/version" \
      | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' >> "$out" || echo "ERROR" >> "$out"
  done
  echo "---- $(date '+%H:%M:%S') ${HOST} 共 ${COUNT} 次 ----"
  sort "$out" | uniq -c | sort -rn | awk -v total="$COUNT" '{ printf "  %-14s %4d 次  %5.1f%%\n", $2, $1, $1 * 100 / total }'
  rm -f "$out"
}

if [ "$WATCH" = "1" ]; then
  while true; do
    one_round
    sleep 5
  done
else
  one_round
fi
