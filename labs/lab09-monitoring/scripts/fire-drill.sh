#!/usr/bin/env bash
# Lab 09：故障演练，用 mall-api 的 /api/debug/* 接口触发告警，验证 指标 → 规则 → Alertmanager → 群消息 整条链路
#
# 前提：mall-api 开启了 MALL_DEBUG=true（kubectl -n mall set env deploy/mall-api MALL_DEBUG=true）
# 用法（学员电脑或任意一台能解析 mall.lab.local 的虚拟机）：
#   ./fire-drill.sh traffic 300    # 只打正常流量 300 秒，给大盘造数据
#   ./fire-drill.sh error   600    # 正常流量 + 约 30% 请求打 /api/debug/error，触发 MallApiHighErrorRate
#   ./fire-drill.sh slow    600    # 正常流量 + 约 20% 请求打 /api/debug/slow?ms=2500，触发 MallApiHighLatency
#   ./fire-drill.sh order   120    # 每秒下 1 单，让"订单数"面板有数据
# 环境变量 BASE_URL 默认 http://mall.lab.local，也可以填 http://\<网关IP\> 或 port-forward 后的 http://127.0.0.1:8080
set -euo pipefail

BASE_URL="${BASE_URL:-http://mall.lab.local}"
MODE="${1:-}"
DURATION="${2:-300}"

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

[[ -n "$MODE" ]] || usage
[[ "$DURATION" =~ ^[0-9]+$ ]] || usage

hit() {
  # 只取状态码，-m 10 防止慢接口把脚本卡死
  curl -s -o /dev/null -m 10 -w '%{http_code}' "$@" || echo "000"
}

check_debug() {
  local code
  code="$(hit "$BASE_URL/api/debug/error")"
  if [[ "$code" == "404" ]]; then
    echo "/api/debug/error 返回 404：mall-api 没开 MALL_DEBUG=true，先执行"
    echo "  kubectl -n mall set env deploy/mall-api MALL_DEBUG=true"
    exit 1
  fi
}

normal_once() {
  hit "$BASE_URL/api/products" >/dev/null
  hit "$BASE_URL/api/products/$((RANDOM % 6 + 1))" >/dev/null
}

end=$((SECONDS + DURATION))
count=0
case "$MODE" in
  traffic) ;;
  error | slow) check_debug ;;
  order) ;;
  *) usage ;;
esac

echo "开始演练：mode=$MODE duration=${DURATION}s base=$BASE_URL"
while ((SECONDS < end)); do
  case "$MODE" in
    traffic)
      normal_once
      ;;
    error)
      normal_once
      # 正常请求 2 个 + 错误请求 1 个，5xx 比例大约 33%
      hit "$BASE_URL/api/debug/error" >/dev/null
      ;;
    slow)
      normal_once
      # 放到后台，不阻塞正常流量；每轮 1 个慢请求 + 2 个正常请求
      hit "$BASE_URL/api/debug/slow?ms=2500" >/dev/null &
      ;;
    order)
      # 只买库存最多的 5 号（999 件）和 6 号（200 件）商品，免得很快卖空返回 409
      code="$(hit -X POST -H 'Content-Type: application/json' \
        -d "{\"product_id\":$((RANDOM % 2 + 5)),\"quantity\":1}" "$BASE_URL/api/orders")"
      [[ "$code" == "201" ]] || echo "下单返回 ${code}（409 表示库存不足，属于正常业务错误）"
      ;;
  esac
  count=$((count + 1))
  if ((count % 50 == 0)); then
    echo "已发送 $count 轮，剩余 $((end - SECONDS))s"
  fi
  if [[ "$MODE" == "order" ]]; then sleep 1; else sleep 0.3; fi
done
wait
echo "演练结束，共 $count 轮。告警恢复需要等 5 分钟窗口滑过去。"
