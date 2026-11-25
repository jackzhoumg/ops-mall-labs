#!/usr/bin/env bash
# Nginx 访问日志统计：访问量 Top IP、状态码分布、5xx 最多的接口、慢请求
#
# 用法：
#   ./nginx_log_stats.sh                                   # 默认分析 /var/log/nginx/access.log
#   ./nginx_log_stats.sh -n 20 -s 0.5 /var/log/nginx/access.log /var/log/nginx/access.log-*.gz
#
# 支持两种日志格式（按双引号切分字段，URL 或 UA 里有空格也不会错位）：
#   combined：Nginx 默认格式，没有耗时字段，慢请求统计会跳过
#   ops     ：combined + 末尾 "$upstream_response_time $request_time"（Lab 03 Ansible nginx 角色里定义）
#
# 对应教程：Lab 03 Shell / Python 与 Ansible 自动化

set -Eeuo pipefail

TOP_N=10
SLOW_SECONDS=1
LOG_DIR="${LOG_DIR:-/var/log/ops}"
LOG_FILE="${LOG_DIR}/nginx_log_stats.log"
TMP_FILE=""

usage() {
  cat <<EOF
用法: $0 [-n TopN] [-s 慢请求阈值秒] [日志文件 ...]
  -n  Top 排名条数，默认 ${TOP_N}
  -s  超过多少秒算慢请求，默认 ${SLOW_SECONDS}
  日志文件可以多个，.gz 结尾的自动解压读取；不写默认 /var/log/nginx/access.log
EOF
}

log() {
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >> "$LOG_FILE"
}

read_logs() {
  # 把所有日志文件合并成一个流输出
  local f
  for f in "$@"; do
    if [[ "$f" == *.gz ]]; then
      gzip -dc -- "$f"
    else
      cat -- "$f"
    fi
  done
}

section() {
  printf '\n==== %s ====\n' "$1"
}

main() {
  while getopts ":n:s:h" opt; do
    case "$opt" in
      n) TOP_N="$OPTARG" ;;
      s) SLOW_SECONDS="$OPTARG" ;;
      h) usage; exit 0 ;;
      *) usage; exit 2 ;;
    esac
  done
  shift $((OPTIND - 1))

  local files=("$@")
  if (( ${#files[@]} == 0 )); then
    files=(/var/log/nginx/access.log)
  fi
  local f
  for f in "${files[@]}"; do
    if [[ ! -r "$f" ]]; then
      echo "读不到日志文件：$f" >&2
      exit 2
    fi
  done

  if ! mkdir -p "$LOG_DIR" 2>/dev/null || [[ ! -w "$LOG_DIR" ]]; then
    LOG_FILE=/tmp/nginx_log_stats.log
  fi
  log INFO "开始统计 ${files[*]}"

  # 先切出需要的字段，存成临时文件，后面多次统计只读一遍原始日志
  # 输出列：ip status method path request_time（没有耗时字段时为 -）
  TMP_FILE=$(mktemp)
  trap 'rm -f "$TMP_FILE"' EXIT
  local tmp="$TMP_FILE"

  read_logs "${files[@]}" | awk -F'"' '
    NF >= 6 {
      split($1, a, " "); ip = a[1]
      split($2, r, " "); method = r[1]; path = r[2]
      sub(/\?.*/, "", path)                     # 去掉查询参数，/api/products?id=1 和 ?id=2 算同一个接口
      if (path == "") path = "-"
      split($3, s, " "); status = s[1]
      rt = "-"
      if (NF >= 7) {
        n = split($7, t, " ")
        if (n > 0 && t[n] ~ /^[0-9.]+$/) rt = t[n]  # 最后一个字段是 $request_time
      }
      print ip, status, method, path, rt
    }' > "$tmp"

  local total
  total=$(wc -l < "$tmp")
  if (( total == 0 )); then
    echo "没有解析到任何请求，确认日志格式是 combined 或 ops"
    exit 0
  fi

  section "总览"
  awk '{ ip[$1] = 1 } END { printf "请求总数: %d\n独立 IP 数: %d\n", NR, length(ip) }' "$tmp"

  section "访问量 Top ${TOP_N} IP"
  awk '{ c[$1]++ } END { for (i in c) printf "%8d  %s\n", c[i], i }' "$tmp" | sort -rn | head -n "$TOP_N"

  section "状态码分布"
  awk -v total="$total" '{ c[$2]++ } END { for (s in c) printf "%s  %8d  %6.2f%%\n", s, c[s], c[s] * 100 / total }' "$tmp" | sort

  section "5xx 最多的接口 Top ${TOP_N}"
  awk '$2 ~ /^5/ { c[$3 " " $4]++ } END { for (k in c) printf "%8d  %s\n", c[k], k }' "$tmp" | sort -rn | head -n "$TOP_N"

  section "慢请求（> ${SLOW_SECONDS}s）按接口汇总 Top ${TOP_N}"
  if ! awk '$5 != "-" { found = 1; exit } END { exit !found }' "$tmp"; then
    echo "日志里没有 request_time 字段，跳过。把 log_format 改成 ops 格式（见教程）再统计。"
  else
    awk -v slow="$SLOW_SECONDS" '
      $5 != "-" && $5 + 0 > slow + 0 {
        k = $3 " " $4; c[k]++; sum[k] += $5
        if ($5 + 0 > max[k] + 0) max[k] = $5
      }
      END { for (k in c) printf "%8d  平均 %6.3fs  最大 %6.3fs  %s\n", c[k], sum[k] / c[k], max[k], k }' "$tmp" \
      | sort -rn | head -n "$TOP_N"
  fi

  log INFO "统计完成，共 ${total} 条请求"
}

main "$@"
