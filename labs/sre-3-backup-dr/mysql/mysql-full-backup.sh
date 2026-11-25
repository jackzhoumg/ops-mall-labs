#!/usr/bin/env bash
# MySQL 逻辑全备：mysqldump 一致性快照 + 压缩 + 校验 + 上传 MinIO + 清理过期备份。
# 由 systemd 定时器 mall-mysql-full-backup.timer 每天 02:00 调用，也可以手工执行。
#
# 用法（lab-db1，root）：
#   sudo bash mysql/mysql-full-backup.sh
#   sudo ENV_FILE=/etc/mall-backup/backup.env bash mysql/mysql-full-backup.sh
#
# 备份文件：<BACKUP_DIR>/full/mall-full-YYYYmmdd-HHMMSS.sql.gz（+ .sha256、.meta）
# 远端位置：<RCLONE_REMOTE>/full/
set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/mall-backup/backup.env}"
# shellcheck source=/dev/null
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

: "${RCLONE_REMOTE:?RCLONE_REMOTE 未设置}"
: "${BACKUP_DIR:?BACKUP_DIR 未设置}"
: "${MYSQL_DEFAULTS:?MYSQL_DEFAULTS 未设置}"
KEEP_LOCAL_DAYS="${KEEP_LOCAL_DAYS:-3}"
REMOTE_KEEP_DAYS="${REMOTE_KEEP_DAYS:-0}"
DATABASES="${DATABASES:-mall}"
TEXTFILE_DIR="${TEXTFILE_DIR:-}"
RCLONE_CONFIG="${RCLONE_CONFIG:-}"
export RCLONE_CONFIG

log() { echo "$(date '+%F %T') [full-backup] $*"; }

# 写一个 Prometheus 指标，给“备份多久没成功了”的告警用
write_metric() {
  local status="$1" bytes="${2:-0}"
  [[ -n "$TEXTFILE_DIR" && -d "$TEXTFILE_DIR" ]] || return 0
  local f="$TEXTFILE_DIR/mall_mysql_backup_full.prom"
  {
    echo "# HELP mall_mysql_backup_last_run_timestamp_seconds 最近一次备份执行时间"
    echo "# TYPE mall_mysql_backup_last_run_timestamp_seconds gauge"
    echo "mall_mysql_backup_last_run_timestamp_seconds{type=\"full\"} $(date +%s)"
    echo "# HELP mall_mysql_backup_last_status 最近一次备份结果，1 成功 0 失败"
    echo "# TYPE mall_mysql_backup_last_status gauge"
    echo "mall_mysql_backup_last_status{type=\"full\"} $status"
    if [[ "$status" == 1 ]]; then
      echo "# HELP mall_mysql_backup_last_success_timestamp_seconds 最近一次备份成功时间"
      echo "# TYPE mall_mysql_backup_last_success_timestamp_seconds gauge"
      echo "mall_mysql_backup_last_success_timestamp_seconds{type=\"full\"} $(date +%s)"
      echo "# HELP mall_mysql_backup_size_bytes 最近一次备份文件大小"
      echo "# TYPE mall_mysql_backup_size_bytes gauge"
      echo "mall_mysql_backup_size_bytes{type=\"full\"} $bytes"
    fi
  } > "$f.tmp" && mv "$f.tmp" "$f"
}

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

on_error() {
  log "备份失败（第 $1 行）"
  write_metric 0
  rm -f "${tmp:-}"
}
trap 'on_error $LINENO' ERR

ts="$(date +%Y%m%d-%H%M%S)"
dir="$BACKUP_DIR/full"
name="mall-full-$ts.sql.gz"
file="$dir/$name"
tmp="$file.tmp"
mkdir -p "$dir"
chmod 700 "$BACKUP_DIR"

read -r -a dbs <<< "$DATABASES"
log "开始全备：库 ${DATABASES}，输出 ${file}"

# --single-transaction：InnoDB 一致性快照，备份期间不锁表，业务照常读写
# --flush-logs       ：备份开始时切一个新 binlog，全备和增量的边界清清楚楚
# --source-data=2    ：把备份时刻的 binlog 文件名和位点以注释写进备份，恢复时从这里开始重放
# --set-gtid-purged=ON：写入 GTID_PURGED，恢复后的实例知道哪些事务已经包含在全备里
mysqldump --defaults-extra-file="$MYSQL_DEFAULTS" \
  --single-transaction --flush-logs --source-data=2 --set-gtid-purged=ON \
  --routines --triggers --events --hex-blob --no-tablespaces \
  --databases "${dbs[@]}" | gzip -6 > "$tmp"

# 校验：压缩包完整，并且 mysqldump 正常结束（最后一行是 Dump completed）
gzip -t "$tmp"
if ! gzip -dc "$tmp" | tail -n 1 | grep -q 'Dump completed'; then
  log "备份文件不完整：没有 Dump completed 结束标记"
  false
fi
mv "$tmp" "$file"

# 记录恢复要用的元数据：binlog 起点和 GTID
meta="$dir/mall-full-$ts.meta"
{
  echo "backup_file=$name"
  echo "created_at=$(date '+%F %T %z')"
  echo "source_host=$(hostname)"
  # 备份头部的注释形如：-- CHANGE REPLICATION SOURCE TO SOURCE_LOG_FILE='binlog.000012', SOURCE_LOG_POS=158;
  gzip -dc "$file" | head -n 60 | grep -m1 -o "SOURCE_LOG_FILE='[^']*', SOURCE_LOG_POS=[0-9]*" \
    | awk -F"'" '{ split($3, a, "="); print "binlog_file=" $2; print "binlog_pos=" a[2] }' || true
} > "$meta"
(cd "$dir" && sha256 "$name" > "$name.sha256")

bytes="$(wc -c < "$file" | tr -d ' ')"
log "本地备份完成：$(du -h "$file" | cut -f1)，$(grep binlog_file "$meta" || echo 'binlog_file=未知')"

# 上传：备份文件、校验和、元数据一起传
rclone copy "$dir" "$RCLONE_REMOTE/full/" --include "mall-full-$ts.*" --immutable
# 远端核对：大小和本地一致
rclone check "$dir" "$RCLONE_REMOTE/full/" --include "$name" --one-way
log "已上传到 $RCLONE_REMOTE/full/"

# 清理过期备份
find "$dir" -name 'mall-full-*' -type f -mtime +"$KEEP_LOCAL_DAYS" -print -delete | sed 's/^/删除本地过期备份 /'
if [[ "$REMOTE_KEEP_DAYS" -gt 0 ]]; then
  rclone delete "$RCLONE_REMOTE/full/" --min-age "${REMOTE_KEEP_DAYS}d" --include 'mall-full-*'
fi

write_metric 1 "$bytes"
log "全备完成"
