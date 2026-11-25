#!/usr/bin/env bash
# 服务器巡检脚本：CPU / 内存 / 磁盘 / 负载 / 服务状态 / 证书到期
#
# 用法：
#   sudo ./inspect.sh
#   SERVICES="nginx mall-api" CERT_FILES="/etc/nginx/ssl/mall.lab.local.crt" sudo ./inspect.sh
#   CERT_HOSTS="mall.lab.local:443" ./inspect.sh
#
# 退出码：0 全部正常；1 有告警项（方便 cron、监控系统判断）；2 脚本自身出错
# 对应教程：Lab 03 Shell / Python 与 Ansible 自动化

# -E 让 ERR trap 在函数里也生效；-e 出错即退；-u 用到未定义变量报错；pipefail 管道中任一命令失败都算失败
set -Eeuo pipefail

# ---------- 可通过环境变量覆盖的阈值 ----------
CPU_WARN="${CPU_WARN:-80}"                 # CPU 使用率 %
MEM_WARN="${MEM_WARN:-85}"                 # 内存使用率 %（按 MemAvailable 计算）
DISK_WARN="${DISK_WARN:-85}"               # 磁盘使用率 %
INODE_WARN="${INODE_WARN:-85}"             # inode 使用率 %
LOAD_WARN_RATIO="${LOAD_WARN_RATIO:-1.5}"  # 1 分钟负载 / CPU 核数
CERT_WARN_DAYS="${CERT_WARN_DAYS:-30}"     # 证书剩余天数
SERVICES="${SERVICES:-ssh chrony cron}"   # 要检查的 systemd 服务，空格分隔（Ubuntu 上是 ssh 不是 sshd）
CERT_FILES="${CERT_FILES:-}"               # 本地证书文件，空格分隔
CERT_HOSTS="${CERT_HOSTS:-}"               # 远程地址 host:port，空格分隔

LOG_DIR="${LOG_DIR:-/var/log/ops}"
LOG_FILE="${LOG_DIR}/inspect.log"
LOCK_FILE="${LOCK_FILE:-/tmp/ops-inspect.lock}"

WARN_COUNT=0

log() {
  # 同时输出到屏幕和日志文件，带时间和级别
  local level="$1"; shift
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$*" | tee -a "$LOG_FILE"
}

report() {
  # report OK|WARN 项目 详情
  local status="$1" item="$2" detail="$3"
  if [[ "$status" == "WARN" ]]; then
    WARN_COUNT=$((WARN_COUNT + 1))
  fi
  log "$status" "$(printf '%-8s %s' "$item" "$detail")"
}

on_error() {
  log "ERROR" "巡检脚本在第 $1 行出错，退出码 $2"
  exit 2
}

check_cpu() {
  # 读两次 /proc/stat，间隔 1 秒，算这 1 秒内的 CPU 使用率
  local u1 n1 s1 i1 w1 x1 y1 z1 u2 n2 s2 i2 w2 x2 y2 z2
  read -r _ u1 n1 s1 i1 w1 x1 y1 z1 _ < /proc/stat
  sleep 1
  read -r _ u2 n2 s2 i2 w2 x2 y2 z2 _ < /proc/stat
  local total=$(( (u2+n2+s2+i2+w2+x2+y2+z2) - (u1+n1+s1+i1+w1+x1+y1+z1) ))
  local idle=$(( (i2+w2) - (i1+w1) ))
  local usage=0
  if (( total > 0 )); then
    usage=$(( (total - idle) * 100 / total ))
  fi
  if (( usage >= CPU_WARN )); then
    report WARN "CPU" "使用率 ${usage}% >= ${CPU_WARN}%，用 top / pidstat 看是哪个进程"
  else
    report OK "CPU" "使用率 ${usage}%"
  fi
}

check_mem() {
  local total avail used_pct
  total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  used_pct=$(( (total - avail) * 100 / total ))
  if (( used_pct >= MEM_WARN )); then
    report WARN "MEM" "使用率 ${used_pct}%（可用 $((avail / 1024))MB），看 ps aux --sort=-rss | head"
  else
    report OK "MEM" "使用率 ${used_pct}%（可用 $((avail / 1024))MB）"
  fi
}

check_load() {
  local load1 cores
  read -r load1 _ < /proc/loadavg
  cores=$(nproc)
  # bash 不能直接比较小数，交给 awk
  if awk -v l="$load1" -v c="$cores" -v r="$LOAD_WARN_RATIO" 'BEGIN { exit !(l / c >= r) }'; then
    report WARN "LOAD" "1 分钟负载 ${load1}，CPU ${cores} 核，超过 ${LOAD_WARN_RATIO} 倍"
  else
    report OK "LOAD" "1 分钟负载 ${load1}，CPU ${cores} 核"
  fi
}

check_disk() {
  local found=0 line mount pct
  # -P 保证一个挂载点一行；排除内存文件系统和容器 overlay
  while read -r line; do
    pct=$(awk '{gsub("%", "", $5); print $5}' <<< "$line")
    mount=$(awk '{print $6}' <<< "$line")
    if (( pct >= DISK_WARN )); then
      report WARN "DISK" "${mount} 使用率 ${pct}%，用 du -xh --max-depth=1 ${mount} | sort -h 找大目录"
      found=1
    fi
  done < <(df -P -x tmpfs -x devtmpfs -x overlay -x squashfs | tail -n +2)

  while read -r line; do
    pct=$(awk '{gsub("%", "", $5); print $5}' <<< "$line")
    mount=$(awk '{print $6}' <<< "$line")
    [[ "$pct" == "-" ]] && continue
    if (( pct >= INODE_WARN )); then
      report WARN "INODE" "${mount} inode 使用率 ${pct}%，多半是海量小文件（session、缓存、日志碎片）"
      found=1
    fi
  done < <(df -P -i -x tmpfs -x devtmpfs -x overlay -x squashfs | tail -n +2)

  if (( found == 0 )); then
    report OK "DISK" "所有挂载点使用率和 inode 均低于 ${DISK_WARN}%"
  fi
}

check_services() {
  local svc state
  for svc in $SERVICES; do
    # is-active 在服务不正常时返回非 0，加 || true 防止 set -e 直接退出
    state=$(systemctl is-active "$svc" 2>/dev/null || true)
    if [[ "$state" == "active" ]]; then
      report OK "SERVICE" "${svc} active"
    else
      report WARN "SERVICE" "${svc} ${state:-unknown}，用 systemctl status ${svc} / journalctl -u ${svc} -n 50 看原因"
    fi
  done
}

cert_days_left() {
  # 输入 notAfter 字符串，输出剩余天数（GNU date）
  local end_date="$1" end_ts now_ts
  end_ts=$(date -d "$end_date" +%s)
  now_ts=$(date +%s)
  echo $(( (end_ts - now_ts) / 86400 ))
}

check_cert_end() {
  local name="$1" end_date="$2" days
  if [[ -z "$end_date" ]]; then
    report WARN "CERT" "${name} 读取证书失败"
    return
  fi
  days=$(cert_days_left "$end_date")
  if (( days < CERT_WARN_DAYS )); then
    report WARN "CERT" "${name} 剩余 ${days} 天到期（${end_date}）"
  else
    report OK "CERT" "${name} 剩余 ${days} 天"
  fi
}

check_certs() {
  local f hp end_date
  for f in $CERT_FILES; do
    if [[ ! -r "$f" ]]; then
      report WARN "CERT" "${f} 不存在或没有读权限"
      continue
    fi
    end_date=$(openssl x509 -enddate -noout -in "$f" 2>/dev/null | cut -d= -f2 || true)
    check_cert_end "$f" "$end_date"
  done
  for hp in $CERT_HOSTS; do
    # -servername 带上 SNI，否则多证书的站点会拿到默认证书
    end_date=$(echo | timeout 5 openssl s_client -connect "$hp" -servername "${hp%%:*}" 2>/dev/null \
      | openssl x509 -enddate -noout 2>/dev/null | cut -d= -f2 || true)
    check_cert_end "$hp" "$end_date"
  done
}

main() {
  # 普通用户没权限写 /var/log/ops 时退回 /tmp，免得脚本直接失败
  if ! mkdir -p "$LOG_DIR" 2>/dev/null || [[ ! -w "$LOG_DIR" ]]; then
    LOG_DIR=/tmp
    LOG_FILE="${LOG_DIR}/inspect.log"
  fi
  # 锁防重入：上一次还没跑完（比如 df 卡在坏掉的 NFS 上），这次直接退出
  exec 9> "$LOCK_FILE"
  if ! flock -n 9; then
    log "WARN" "上一次巡检还在运行，本次跳过"
    exit 0
  fi
  trap 'on_error $LINENO $?' ERR

  log "INFO" "===== 开始巡检 $(hostname) ====="
  check_cpu
  check_mem
  check_load
  check_disk
  check_services
  check_certs
  if (( WARN_COUNT > 0 )); then
    log "INFO" "===== 巡检结束：${WARN_COUNT} 项告警 ====="
    exit 1
  fi
  log "INFO" "===== 巡检结束：全部正常 ====="
}

main "$@"
