#!/usr/bin/env bash
# 演练时的“秒表”：每秒探测一次商城的读接口和写接口，记录每次失败，按 Ctrl-C 结束后算出实际中断时长。
# 演练报告里的“实际 RTO”就用它的输出，不要凭感觉估。
#
# 用法（学员电脑，演练开始前启动）：
#   bash scripts/probe-availability.sh | tee probe-$(date +%Y%m%d-%H%M).log
#   WRITE=0 bash scripts/probe-availability.sh      # 只探测读接口（不产生订单）
#
# 环境变量：
#   BASE_URL   默认 http://mall.lab.local
#   INTERVAL   探测间隔秒数，默认 1
#   WRITE      1 = 同时探测下单接口（每次下 1 件 6 号商品），默认 1
#   CURL_OPTS  额外 curl 参数，比如自签证书用 "-k"
set -uo pipefail

BASE_URL="${BASE_URL:-http://mall.lab.local}"
INTERVAL="${INTERVAL:-1}"
WRITE="${WRITE:-1}"
CURL_OPTS="${CURL_OPTS:-}"

curl_args=(-s -o /dev/null -w '%{http_code}' --max-time 3)
if [ -n "$CURL_OPTS" ]; then
  read -r -a extra <<< "$CURL_OPTS"
  curl_args+=("${extra[@]}")
fi

start=$(date +%s)
read_fail=0 write_fail=0 total=0
read_down_since="" write_down_since=""
read_outages="" write_outages=""

summary() {
  local end
  end=$(date +%s)
  # 结束时还没恢复的，也算一段
  [ -n "$read_down_since" ] && read_outages="${read_outages} $(( end - read_down_since ))s(未恢复)"
  [ -n "$write_down_since" ] && write_outages="${write_outages} $(( end - write_down_since ))s(未恢复)"
  echo
  echo "======== 探测结果 ========"
  echo "探测时长：$(( end - start )) 秒，共 ${total} 轮"
  echo "读接口失败：${read_fail} 次，中断区间：${read_outages:- 无}"
  if [ "$WRITE" = "1" ]; then
    echo "写接口失败：${write_fail} 次，中断区间：${write_outages:- 无}"
  fi
  echo "（实际 RTO 取最长的那段中断；读写分开看，主从切换时往往读先恢复）"
  exit 0
}
trap summary INT TERM

echo "开始探测 ${BASE_URL}，每 ${INTERVAL} 秒一次，Ctrl-C 结束"
while true; do
  now=$(date +%s)
  ts=$(date '+%T')
  total=$(( total + 1 ))

  r=$(curl "${curl_args[@]}" "${BASE_URL}/api/products")
  if [ "$r" = "200" ]; then
    if [ -n "$read_down_since" ]; then
      echo "${ts} 读接口恢复，中断 $(( now - read_down_since )) 秒"
      read_outages="${read_outages} $(( now - read_down_since ))s"
      read_down_since=""
    fi
  else
    read_fail=$(( read_fail + 1 ))
    [ -z "$read_down_since" ] && { read_down_since=$now; echo "${ts} 读接口失败（HTTP ${r}）"; }
  fi

  if [ "$WRITE" = "1" ]; then
    w=$(curl "${curl_args[@]}" -H 'Content-Type: application/json' -H 'X-Load-Test: true' \
      -d '{"product_id":6,"quantity":1}' "${BASE_URL}/api/orders")
    if [ "$w" = "201" ] || [ "$w" = "409" ]; then
      if [ -n "$write_down_since" ]; then
        echo "${ts} 写接口恢复，中断 $(( now - write_down_since )) 秒"
        write_outages="${write_outages} $(( now - write_down_since ))s"
        write_down_since=""
      fi
    else
      write_fail=$(( write_fail + 1 ))
      [ -z "$write_down_since" ] && { write_down_since=$now; echo "${ts} 写接口失败（HTTP ${w}）"; }
    fi
  fi

  # 每 30 轮打印一次心跳，确认脚本还在跑
  [ $(( total % 30 )) -eq 0 ] && echo "${ts} 运行中：${total} 轮，读失败 ${read_fail}，写失败 ${write_fail}"
  sleep "$INTERVAL"
done
