#!/usr/bin/env bash
# 从 Prometheus 读出 mall-api 的 SLO 状态，打印成一张表：SLI、目标、剩余预算、燃烧率。
# 周会、发布评审前跑一下，比截图大盘方便。
#
# 用法（任意能访问 Prometheus 的机器，需要 curl 和 jq）：
#   bash scripts/slo-report.sh
#   PROM_URL=http://127.0.0.1:9090 bash scripts/slo-report.sh   # 配合 kubectl port-forward
#
# 依赖 slo/rules/mall-api-slo.rules.yml 里的记录规则（手写版）。
set -euo pipefail

PROM_URL="${PROM_URL:-http://prometheus.lab.local}"
SERVICE="${SERVICE:-mall-api}"
PERIOD_DAYS="${PERIOD_DAYS:-30}"

command -v jq >/dev/null || { echo "需要 jq：sudo dnf install -y jq" >&2; exit 1; }

# query <PromQL> <slo>：返回一个数字，没数据返回 NaN
query() {
  local expr="$1" slo="$2"
  curl -sf --max-time 10 "$PROM_URL/api/v1/query" --data-urlencode "query=${expr}{service=\"${SERVICE}\",slo=\"${slo}\"}" \
    | jq -r '.data.result[0].value[1] // "NaN"'
}

pct() { awk -v v="$1" 'BEGIN { if (v == "NaN") print "无数据"; else printf "%.3f%%", v * 100 }'; }
num() { awk -v v="$1" 'BEGIN { if (v == "NaN") print "无数据"; else printf "%.2f", v }'; }

if ! curl -sf --max-time 5 "$PROM_URL/-/ready" >/dev/null; then
  echo "连不上 Prometheus：$PROM_URL" >&2
  exit 1
fi

printf '服务：%s    统计窗口：%s 天    时间：%s\n\n' "$SERVICE" "$PERIOD_DAYS" "$(date '+%F %T')"
printf '%-13s %-10s %-12s %-12s %-14s %-10s %-10s %-10s\n' "SLO" "目标" "30天SLI" "剩余预算" "预算折合分钟" "燃烧率1h" "燃烧率6h" "燃烧率3d"

for slo in availability latency; do
  objective=$(query 'slo:objective:ratio' "$slo")
  err30d=$(query 'slo:sli_error:ratio_rate30d' "$slo")
  remaining=$(query 'slo:error_budget_remaining:ratio' "$slo")
  b1h=$(query 'slo:burn_rate:1h' "$slo")
  b6h=$(query 'slo:burn_rate:6h' "$slo")
  b3d=$(query 'slo:burn_rate:3d' "$slo")

  sli=$(awk -v e="$err30d" 'BEGIN { if (e == "NaN") print "NaN"; else print 1 - e }')
  # 预算折合时间：30 天 × 预算比例 × 剩余比例。只有“按时间算”的可用性才直观，延迟 SLO 仅供参考
  minutes=$(awk -v o="$objective" -v r="$remaining" -v d="$PERIOD_DAYS" \
    'BEGIN { if (o == "NaN" || r == "NaN") print "无数据"; else printf "%.1f", d * 24 * 60 * (1 - o) * r }')

  printf '%-13s %-10s %-12s %-12s %-14s %-10s %-10s %-10s\n' \
    "$slo" "$(pct "$objective")" "$(pct "$sli")" "$(pct "$remaining")" "$minutes" \
    "$(num "$b1h")" "$(num "$b6h")" "$(num "$b3d")"
done

cat <<'EOF'

怎么看：
  剩余预算 < 0      违反 SLO，按错误预算政策冻结功能发布
  燃烧率 1h > 14.4  1 小时烧掉 2% 预算，应该已经有 page 告警
  燃烧率 = 1        正好在周期末用完预算
EOF
