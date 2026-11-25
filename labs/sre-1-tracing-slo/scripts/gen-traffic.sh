#!/usr/bin/env bash
# 给 mall-api 造持续的背景流量，可以按比例混入 500 错误和慢请求，用来“烧”错误预算、触发 SLO 告警。
# 只用 curl，Rocky / Ubuntu / macOS 自带的 bash 都能跑。
#
# 用法（学员电脑或 k8s-master，能访问 mall.lab.local 即可）：
#   bash scripts/gen-traffic.sh                              # 正常流量，跑 30 分钟
#   ERROR_PCT=10 DURATION=1800 bash scripts/gen-traffic.sh   # 10% 的请求打 /api/debug/error
#   SLOW_PCT=20 SLOW_MS=800 bash scripts/gen-traffic.sh      # 20% 的请求超过 500ms
#
# 注入错误和慢请求需要 mall-api 开启 MALL_DEBUG=true（教程第 5 步有命令），用完记得关掉。
#
# 环境变量：
#   BASE_URL   默认 http://mall.lab.local
#   DURATION   持续秒数，默认 1800
#   WORKERS    并发数，默认 4
#   ERROR_PCT  打 /api/debug/error 的百分比，默认 0
#   SLOW_PCT   打 /api/debug/slow 的百分比，默认 0
#   SLOW_MS    慢请求耗时，默认 800
#   ORDER_PCT  下单请求的百分比，默认 5（会扣库存，压测前看 SRE-2 的数据准备）
#   CURL_OPTS  额外 curl 参数，比如自签证书用 "-k"
set -uo pipefail

BASE_URL="${BASE_URL:-http://mall.lab.local}"
DURATION="${DURATION:-1800}"
WORKERS="${WORKERS:-4}"
ERROR_PCT="${ERROR_PCT:-0}"
SLOW_PCT="${SLOW_PCT:-0}"
SLOW_MS="${SLOW_MS:-800}"
ORDER_PCT="${ORDER_PCT:-5}"
CURL_OPTS="${CURL_OPTS:-}"

# curl 公共参数放进数组，CURL_OPTS 按空格拆开追加（数组永远不为空，兼容 macOS 自带的 bash 3.2）
curl_args=(-s -o /dev/null -w '%{http_code}' --max-time 10)
if [ -n "$CURL_OPTS" ]; then
  read -r -a extra <<< "$CURL_OPTS"
  curl_args+=("${extra[@]}")
fi

tmpdir="$(mktemp -d)"
pids=""
cleanup() {
  # 只杀自己起的 worker，不用 kill 0（那会把管道里的 tail 等进程一起杀掉）
  # shellcheck disable=SC2086 # pids 是空格分隔的进程号列表，需要拆开
  [ -n "$pids" ] && kill $pids 2>/dev/null
  rm -rf "$tmpdir"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# 先探一下，地址不通就别跑了
if [ "$(curl "${curl_args[@]}" "${BASE_URL}/api/version")" != "200" ]; then
  echo "访问 ${BASE_URL}/api/version 失败，检查 hosts 里的 mall.lab.local 和网关地址" >&2
  exit 1
fi

worker() {
  local id="$1" end=$(( $(date +%s) + DURATION ))
  local out="$tmpdir/worker-$id"
  while [ "$(date +%s)" -lt "$end" ]; do
    local r=$(( RANDOM % 100 )) code
    if [ "$r" -lt "$ERROR_PCT" ]; then
      code=$(curl "${curl_args[@]}" "${BASE_URL}/api/debug/error")
    elif [ "$r" -lt $(( ERROR_PCT + SLOW_PCT )) ]; then
      code=$(curl "${curl_args[@]}" "${BASE_URL}/api/debug/slow?ms=$SLOW_MS")
    elif [ "$r" -lt $(( ERROR_PCT + SLOW_PCT + ORDER_PCT )) ]; then
      code=$(curl "${curl_args[@]}" \
        -H 'Content-Type: application/json' -d '{"product_id":5,"quantity":1}' "${BASE_URL}/api/orders")
    elif [ $(( r % 2 )) -eq 0 ]; then
      code=$(curl "${curl_args[@]}" "${BASE_URL}/api/products")
    else
      code=$(curl "${curl_args[@]}" "${BASE_URL}/api/products/$(( RANDOM % 6 + 1 ))")
    fi
    echo "$code" >> "$out"
    sleep 0.05
  done
}

echo "开始造流量：${BASE_URL}，${WORKERS} 并发，${DURATION} 秒，错误 ${ERROR_PCT}%，慢请求 ${SLOW_PCT}%（${SLOW_MS}ms）"
for i in $(seq 1 "$WORKERS"); do
  worker "$i" &
  pids="$pids $!"
done

# 每 30 秒打印一次累计状态码分布
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt "$DURATION" ]; do
  sleep 30
  total=$(cat "$tmpdir"/worker-* 2>/dev/null | wc -l | tr -d ' ')
  elapsed=$(( $(date +%s) - start ))
  dist=$(cat "$tmpdir"/worker-* 2>/dev/null | sort | uniq -c | awk '{printf "%s=%s ", $2, $1}')
  echo "[$elapsed s] 共 $total 个请求，约 $(( total / (elapsed > 0 ? elapsed : 1) )) 个/秒，状态码：${dist}"
done
wait
