#!/usr/bin/env bash
# steady-state.sh：持续探测商城接口，实时打印每次结果，结束时给出成功率和延迟分位数。
# 对应教程：SRE-4 故障演练与事故管理
#
# 用法（在能访问 mall.lab.local 的机器上执行，比如你的电脑或 k8s-master）：
#   bash steady-state.sh                       # 默认探测 120 秒
#   DURATION=300 bash steady-state.sh          # 探测 300 秒
#   URL=http://mall.lab.local/api/version bash steady-state.sh
#   ORDER=1 bash steady-state.sh               # 每 5 次额外下一单，验证写链路
#
# 稳态判定（可用环境变量调整）：成功率 >= MIN_SUCCESS（默认 99），P95 <= MAX_P95_MS（默认 1000）。
# 满足则退出码 0，不满足退出码 1，方便放进自动化流程。Ctrl+C 提前结束也会输出汇总。
set -euo pipefail

URL="${URL:-http://mall.lab.local/api/products}"
ORDER_URL="${ORDER_URL:-http://mall.lab.local/api/orders}"
DURATION="${DURATION:-120}"
INTERVAL="${INTERVAL:-1}"
TIMEOUT="${TIMEOUT:-5}"
ORDER="${ORDER:-0}"
MIN_SUCCESS="${MIN_SUCCESS:-99}"
MAX_P95_MS="${MAX_P95_MS:-1000}"

command -v curl >/dev/null || {
  echo "需要 curl" >&2
  exit 2
}

samples="$(mktemp)"
trap 'rm -f "$samples"' EXIT

# 输出一行：HTTP 状态码 耗时毫秒。超时或连不上时状态码是 000，耗时记为超时时间
probe() {
  local out
  out="$(curl -s -o /dev/null -m "$TIMEOUT" -w '%{http_code} %{time_total}' "$@" 2>/dev/null || true)"
  [[ -n "$out" ]] || out="000 $TIMEOUT"
  awk -v line="$out" -v t="$TIMEOUT" 'BEGIN {
    split(line, f, " ")
    code = f[1]; secs = f[2]
    if (code == "000" || secs == "") secs = t
    printf "%s %d\n", code, secs * 1000
  }'
}

summary() {
  local total ok
  total="$(wc -l <"$samples" | tr -d ' ')"
  if [[ "$total" -eq 0 ]]; then
    echo "没有采到样本"
    return 1
  fi
  ok="$(awk '$1 ~ /^2/ { n++ } END { print n + 0 }' "$samples")"
  sort -n -k2 "$samples" | awk -v total="$total" -v ok="$ok" -v min_ok="$MIN_SUCCESS" -v max_p95="$MAX_P95_MS" '
    { lat[NR] = $2 }
    END {
      i50 = int(NR * 0.50); if (i50 < 1) i50 = 1
      i95 = int(NR * 0.95); if (i95 < 1) i95 = 1
      rate = ok * 100 / total
      printf "\n==== 汇总 ====\n"
      printf "样本 %d，成功(2xx) %d，成功率 %.2f%%\n", total, ok, rate
      printf "P50 %d ms，P95 %d ms，最大 %d ms\n", lat[i50], lat[i95], lat[NR]
      if (rate >= min_ok && lat[i95] <= max_p95) { print "结论：稳态成立"; exit 0 }
      printf "结论：稳态被打破（要求成功率 >= %s%%，P95 <= %s ms）\n", min_ok, max_p95
      exit 1
    }'
}

on_interrupt() {
  local rc=0
  summary || rc=$?
  exit "$rc"
}
trap on_interrupt INT

echo "探测 ${URL}，持续 ${DURATION}s，每 ${INTERVAL}s 一次"
echo "时间      状态码 耗时ms"

end=$(($(date +%s) + DURATION))
i=0
while [[ "$(date +%s)" -lt "$end" ]]; do
  line="$(probe "$URL")"
  echo "$line" >>"$samples"
  printf '%s  %s\n' "$(date +%H:%M:%S)" "$line"
  if [[ "$ORDER" == "1" && $((i % 5)) -eq 0 ]]; then
    oline="$(probe -X POST -H 'Content-Type: application/json' -d '{"product_id":1,"quantity":1}' "$ORDER_URL")"
    printf '%s  下单 %s\n' "$(date +%H:%M:%S)" "$oline"
  fi
  i=$((i + 1))
  sleep "$INTERVAL"
done
summary
