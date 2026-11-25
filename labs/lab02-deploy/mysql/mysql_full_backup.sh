#!/usr/bin/env bash
# MySQL 全量逻辑备份（mysqldump），Lab 02 手工版
#
# 用法（lab-db1 或 lab-db2 上，root 执行）：
#   sudo bash mysql_full_backup.sh
#   sudo DATABASES="mall" BACKUP_DIR=/data/backup/mysql bash mysql_full_backup.sh
#
# 账号密码放在 /etc/ops/mysql-backup.cnf（见 mysql-backup.cnf.example），不出现在命令行
# 备份文件：/data/backup/mysql/<库名>-<主机名>-<时间>.sql.gz，和 Lab 03 的 mysql_backup.sh 命名一致
# Lab 03 会把它升级成带锁、日志、磁盘检查、过期清理的生产版 mysql_backup.sh
# 对应教程：Lab 02 商城上线 5.6 节
set -Eeuo pipefail

BACKUP_DIR="${BACKUP_DIR:-/data/backup/mysql}"
DATABASES="${DATABASES:-mall}"
MYSQL_DEFAULTS_FILE="${MYSQL_DEFAULTS_FILE:-/etc/ops/mysql-backup.cnf}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

TMP_FILE=""
cleanup() {
  # 失败时删掉半截文件，免得以后拿坏备份去恢复
  if [[ -n "$TMP_FILE" && -f "$TMP_FILE" ]]; then
    rm -f "$TMP_FILE"
  fi
}
trap cleanup EXIT

if [[ ! -r "$MYSQL_DEFAULTS_FILE" ]]; then
  echo "读不到 ${MYSQL_DEFAULTS_FILE}，先按 mysql-backup.cnf.example 创建，并用 root 执行" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

for db in $DATABASES; do
  ts=$(date '+%Y%m%d-%H%M%S')
  file="${BACKUP_DIR}/${db}-$(hostname -s)-${ts}.sql.gz"
  TMP_FILE="${file}.part"
  echo "$(date '+%F %T') 开始备份 ${db} -> ${file}"
  # --single-transaction：InnoDB 一致性快照，备份时不锁表，业务照常读写
  # --source-data=2     ：把备份时刻的 binlog 文件和位置以注释写进文件，时间点恢复从这里开始回放
  # --routines --triggers --events：存储过程、触发器、事件一起备份
  # pipefail 保证 mysqldump 失败时整条管道失败，而不是只看 gzip 的退出码
  mysqldump --defaults-extra-file="$MYSQL_DEFAULTS_FILE" \
    --single-transaction --quick --source-data=2 \
    --routines --triggers --events \
    --databases "$db" | gzip -6 > "$TMP_FILE"
  # 先校验压缩包，再改名。改名是原子操作，看到 .sql.gz 就一定是完整的
  gzip -t "$TMP_FILE"
  mv "$TMP_FILE" "$file"
  TMP_FILE=""
  sha256sum "$file" > "${file}.sha256"
  echo "$(date '+%F %T') 完成 ${db}：$(du -h "$file" | cut -f1)"
done

# 只删本脚本产生的文件
find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.sql.gz' -o -name '*.sql.gz.sha256' \) \
  -mtime +"$RETENTION_DAYS" -print -delete
