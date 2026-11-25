#!/usr/bin/env bash
# 把已经关闭的 binlog 增量上传到对象存储（SeaweedFS）。由 mall-mysql-binlog-upload.timer 每 5 分钟调用。
# RPO（最多丢多少数据）约等于这个间隔：主库连同磁盘一起没了，最多丢最近 5 分钟的事务。
#
# 用法（lab-db1，root：要读 MySQL 数据目录里的 binlog 文件）：
#   sudo bash mysql/mysql-binlog-upload.sh
#
# 远端位置：<RCLONE_REMOTE>/binlog/<HOST_TAG>/binlog.000123
#
# 生产上 RPO 要做到秒级，在另一台机器上用 mysqlbinlog 实时拉取：
#   mysqlbinlog --read-from-remote-server --raw --stop-never -h <主库> -u <复制账号> -p binlog.000001
set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/mall-backup/backup.env}"
# shellcheck source=/dev/null
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

: "${RCLONE_REMOTE:?RCLONE_REMOTE 未设置}"
: "${MYSQL_DEFAULTS:?MYSQL_DEFAULTS 未设置}"
HOST_TAG="${HOST_TAG:-$(hostname -s)}"
FLUSH_BINLOG="${FLUSH_BINLOG:-1}"
TEXTFILE_DIR="${TEXTFILE_DIR:-}"
RCLONE_CONFIG="${RCLONE_CONFIG:-}"
export RCLONE_CONFIG

log() { echo "$(date '+%F %T') [binlog-upload] $*"; }
q() { mysql --defaults-extra-file="$MYSQL_DEFAULTS" -N -B -e "$1"; }

if [[ "$(q 'SELECT @@log_bin')" != "1" ]]; then
  log "这台 MySQL 没开 binlog，没法做时间点恢复，先按 mysql/binlog-settings.cnf 配置"
  exit 1
fi

# 先切一个新文件，让刚才写的事务所在的 binlog 变成“已关闭”，可以安全上传
if [[ "$FLUSH_BINLOG" == "1" ]]; then
  q 'FLUSH BINARY LOGS'
fi

basename_path="$(q 'SELECT @@log_bin_basename')"
binlog_dir="$(dirname "$basename_path")"

list="$(mktemp)"
trap 'rm -f "$list"' EXIT
# SHOW BINARY LOGS 的最后一个是正在写的文件，不上传
q 'SHOW BINARY LOGS' | awk '{print $1}' > "$list.all"
current="$(tail -n 1 "$list.all")"
grep -v -x -F "$current" "$list.all" > "$list" || true
rm -f "$list.all"

count="$(wc -l < "$list" | tr -d ' ')"
if [[ "$count" -eq 0 ]]; then
  log "没有已关闭的 binlog 需要上传（当前文件 ${current}）"
  exit 0
fi

# rclone copy 会跳过远端已有且大小、时间一致的文件，重复执行是安全的
rclone copy "$binlog_dir" "$RCLONE_REMOTE/binlog/$HOST_TAG/" --files-from "$list" --no-traverse
log "已同步 $count 个 binlog 到 $RCLONE_REMOTE/binlog/$HOST_TAG/（最新已关闭：$(tail -n 1 "$list")，当前：${current}）"

if [[ -n "$TEXTFILE_DIR" && -d "$TEXTFILE_DIR" ]]; then
  f="$TEXTFILE_DIR/mall_mysql_backup_binlog.prom"
  {
    echo "# HELP mall_mysql_backup_last_success_timestamp_seconds 最近一次备份成功时间"
    echo "# TYPE mall_mysql_backup_last_success_timestamp_seconds gauge"
    echo "mall_mysql_backup_last_success_timestamp_seconds{type=\"binlog\"} $(date +%s)"
  } > "$f.tmp" && mv "$f.tmp" "$f"
fi
