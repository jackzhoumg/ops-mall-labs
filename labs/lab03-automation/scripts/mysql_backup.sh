#!/usr/bin/env bash
# MySQL 定时逻辑备份：mysqldump + gzip + 校验 + 清理过期文件
#
# 用法（lab-db1 或 lab-db2 上，root 执行）：
#   /usr/local/bin/mysql_backup.sh
#   RETENTION_DAYS=14 DATABASES="mall" /usr/local/bin/mysql_backup.sh
#
# 账号密码放在 MYSQL_DEFAULTS_FILE（默认 /etc/ops/mysql-backup.cnf，权限 600），不出现在命令行和 ps 里：
#   [client]
#   user=backup
#   password=你的备份账号密码
#   socket=/var/lib/mysql/mysql.sock
#
# 定时任务（/etc/cron.d/mysql-backup）：
#   30 2 * * * root /usr/local/bin/mysql_backup.sh >/dev/null 2>&1
#
# 退出码：0 成功；1 失败（同时写日志，方便监控抓取）
# 对应教程：Lab 03 Shell / Python 与 Ansible 自动化

set -Eeuo pipefail

BACKUP_DIR="${BACKUP_DIR:-/data/backup/mysql}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
DATABASES="${DATABASES:-mall}"
MYSQL_DEFAULTS_FILE="${MYSQL_DEFAULTS_FILE:-/etc/ops/mysql-backup.cnf}"
MIN_FREE_MB="${MIN_FREE_MB:-1024}"
LOG_DIR="${LOG_DIR:-/var/log/ops}"
LOG_FILE="${LOG_DIR}/mysql_backup.log"
LOCK_FILE="${LOCK_FILE:-/var/lock/mysql_backup.lock}"

TMP_FILE=""

log() {
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" | tee -a "$LOG_FILE"
}

on_error() {
  log ERROR "备份失败：第 $1 行，退出码 $2"
  # 半截文件一定要删，否则以后恢复时拿到的是坏备份
  [[ -n "$TMP_FILE" && -f "$TMP_FILE" ]] && rm -f "$TMP_FILE"
  exit 1
}

check_env() {
  command -v mysqldump >/dev/null || { log ERROR "找不到 mysqldump"; exit 1; }
  if [[ ! -r "$MYSQL_DEFAULTS_FILE" ]]; then
    log ERROR "账号文件 ${MYSQL_DEFAULTS_FILE} 不存在或不可读"
    exit 1
  fi
  local perm
  perm=$(stat -c '%a' "$MYSQL_DEFAULTS_FILE")
  if [[ "$perm" != "600" && "$perm" != "400" ]]; then
    log WARN "${MYSQL_DEFAULTS_FILE} 权限是 ${perm}，建议 chmod 600（里面有密码）"
  fi
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  local free_mb
  free_mb=$(df -Pm "$BACKUP_DIR" | awk 'NR == 2 { print $4 }')
  if (( free_mb < MIN_FREE_MB )); then
    log ERROR "备份目录剩余 ${free_mb}MB，小于 ${MIN_FREE_MB}MB，不备份，先清理磁盘"
    exit 1
  fi
}

backup_one() {
  local db="$1" ts file
  ts=$(date '+%Y%m%d-%H%M%S')
  file="${BACKUP_DIR}/${db}-$(hostname -s)-${ts}.sql.gz"
  TMP_FILE="${file}.part"

  log INFO "开始备份 ${db} -> ${file}"
  local start=$SECONDS
  # --single-transaction：InnoDB 一致性快照，备份期间不锁表，业务照常读写
  # --source-data=2     ：把备份时刻的 binlog 位置以注释写进文件，做时间点恢复时用（需要 RELOAD、REPLICATION CLIENT 权限）
  # --routines --triggers --events：存储过程、触发器、事件一起备份，默认不带 routines 和 events
  # pipefail 保证 mysqldump 失败时整条管道失败，而不是只看 gzip 的退出码
  mysqldump --defaults-extra-file="$MYSQL_DEFAULTS_FILE" \
    --single-transaction --quick --source-data=2 \
    --routines --triggers --events \
    --databases "$db" | gzip -6 > "$TMP_FILE"

  # 校验压缩包完整，再改名为正式文件。改名是原子操作，看到 .sql.gz 就一定是完整的
  gzip -t "$TMP_FILE"
  mv "$TMP_FILE" "$file"
  TMP_FILE=""
  sha256sum "$file" > "${file}.sha256"

  log INFO "备份完成 ${db}：$(du -h "$file" | cut -f1)，耗时 $((SECONDS - start))s"
}

cleanup_old() {
  local n
  # -mtime +7：最后修改时间在 7 天之前。只删本脚本产生的文件，避免误删目录里的其他东西
  n=$(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.sql.gz' -o -name '*.sql.gz.sha256' -o -name '*.sql.gz.part' \) \
      -mtime +"$RETENTION_DAYS" -print -delete | wc -l)
  log INFO "清理 ${RETENTION_DAYS} 天前的备份文件 ${n} 个"
}

main() {
  if ! mkdir -p "$LOG_DIR" 2>/dev/null || [[ ! -w "$LOG_DIR" ]]; then
    echo "没有权限写 ${LOG_DIR}，请用 root 执行" >&2
    exit 1
  fi
  exec 9> "$LOCK_FILE"
  if ! flock -n 9; then
    log WARN "上一次备份还没结束，本次跳过"
    exit 0
  fi
  trap 'on_error $LINENO $?' ERR

  check_env
  local db
  for db in $DATABASES; do
    backup_one "$db"
  done
  cleanup_old
}

main "$@"
