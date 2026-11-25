#!/usr/bin/env bash
# MySQL 时间点恢复（PITR）：全备 + binlog 重放，恢复到“误操作之前”。
# 恢复目标是一个临时的、新建的 MySQL 实例（默认在 lab-dev 上用 Docker 起一个），
# 绝不直接覆盖线上主库：先在临时实例里核对数据，再把需要的数据导回去。
#
# 用法（lab-dev）：
#   # 方式一：恢复到某个时间点之前（不含这一秒及之后的事务）
#   STOP_DATETIME='2026-11-24 15:30:00' bash mysql/mysql-pitr-restore.sh
#   # 方式二：重放全部 binlog，只跳过误操作那一个事务（误操作之后的正常写入也能保住）
#   EXCLUDE_GTIDS='3e11fa47-71ca-11e1-9e33-c80aa9429562:1234' bash mysql/mysql-pitr-restore.sh
#
# 环境变量：
#   RCLONE_REMOTE   默认 s3backup:mysql-backup
#   RCLONE_CONFIG   默认 ~/.config/rclone/rclone.conf（rclone 自己的默认值）
#   HOST_TAG        备份来源实例，默认 lab-db1
#   WORKDIR         下载和恢复的工作目录，默认 /data/pitr
#   FULL_BACKUP     指定全备文件名；默认自动选择“早于 STOP_DATETIME 的最新一份”
#   STOP_DATETIME   重放到这个时间为止（服务器本地时间，格式 YYYY-mm-dd HH:MM:SS）
#   EXCLUDE_GTIDS   重放时跳过的 GTID（和 STOP_DATETIME 至少给一个）
#   RESTORE_MODE    docker（默认）或 local（恢复到 LOCAL_MYSQL 指向的已有空实例）
#   DOCKER_IMAGE    默认 mysql:8.4（版本不能低于源库）。写作时这个镜像里没有 mysqlbinlog，
#                   脚本会改用本机的 mysqlbinlog：lab-dev 上先加 MySQL 官方 APT 源，
#                   sudo apt install mysql-community-server-core（只装程序文件，不会启动 mysqld）
#   RESTORE_PORT    Docker 模式暴露的端口，默认 3307
#   RESTORE_ROOT_PASSWORD  Docker 模式临时实例的 root 密码，默认 PitrRoot123
#   LOCAL_MYSQL     local 模式连接临时实例的参数，如 "-h127.0.0.1 -P3307 -uroot"
#   SKIP_DOWNLOAD   1 = 不从对象存储下载，直接用 WORKDIR 里已有的文件
set -euo pipefail

RCLONE_REMOTE="${RCLONE_REMOTE:-s3backup:mysql-backup}"
HOST_TAG="${HOST_TAG:-lab-db1}"
WORKDIR="${WORKDIR:-/data/pitr}"
FULL_BACKUP="${FULL_BACKUP:-}"
STOP_DATETIME="${STOP_DATETIME:-}"
EXCLUDE_GTIDS="${EXCLUDE_GTIDS:-}"
RESTORE_MODE="${RESTORE_MODE:-docker}"
DOCKER_IMAGE="${DOCKER_IMAGE:-mysql:8.4}"
RESTORE_PORT="${RESTORE_PORT:-3307}"
RESTORE_ROOT_PASSWORD="${RESTORE_ROOT_PASSWORD:-PitrRoot123}"
LOCAL_MYSQL="${LOCAL_MYSQL:-}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"
CONTAINER=mall-pitr

log() { echo "$(date '+%F %T') [pitr] $*"; }
die() { log "错误：$*"; exit 1; }

[[ -n "$STOP_DATETIME" || -n "$EXCLUDE_GTIDS" ]] || die "STOP_DATETIME 和 EXCLUDE_GTIDS 至少设置一个"
if [[ -n "$STOP_DATETIME" && ! "$STOP_DATETIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
  die "STOP_DATETIME 格式应为 'YYYY-mm-dd HH:MM:SS'，实际是 '$STOP_DATETIME'"
fi
case "$RESTORE_MODE" in
  docker) command -v docker >/dev/null || die "docker 模式需要 Docker（Lab 04 装过）" ;;
  local) [[ -n "$LOCAL_MYSQL" ]] || die "local 模式需要设置 LOCAL_MYSQL" ;;
  *) die "RESTORE_MODE 只能是 docker 或 local" ;;
esac

mkdir -p "$WORKDIR/full" "$WORKDIR/binlog"

# ---------- 1. 选定全备 ----------
if [[ -z "$FULL_BACKUP" ]]; then
  if [[ "$SKIP_DOWNLOAD" == "1" ]]; then
    candidates=""
    for p in "$WORKDIR"/full/mall-full-*.sql.gz; do
      [[ -f "$p" ]] && candidates+="${p##*/}"$'\n'
    done
    candidates="${candidates%$'\n'}"
  else
    candidates="$(rclone lsf "$RCLONE_REMOTE/full/" --include 'mall-full-*.sql.gz')"
  fi
  [[ -n "$candidates" ]] || die "没有找到任何全备"
  if [[ -n "$STOP_DATETIME" ]]; then
    # 文件名里的时间 YYYYmmdd-HHMMSS 和 STOP_DATETIME 转成同样格式后按字符串比较
    key="$(echo "$STOP_DATETIME" | tr -d ':-' | tr ' ' '-')"
    FULL_BACKUP="$(echo "$candidates" | sort | awk -v k="mall-full-$key" '$0 < k' | tail -n 1)"
  else
    FULL_BACKUP="$(echo "$candidates" | sort | tail -n 1)"
  fi
  [[ -n "$FULL_BACKUP" ]] || die "没有早于 $STOP_DATETIME 的全备"
fi
log "使用全备：$FULL_BACKUP"

# ---------- 2. 下载全备和 binlog ----------
if [[ "$SKIP_DOWNLOAD" != "1" ]]; then
  base="${FULL_BACKUP%.sql.gz}"
  rclone copy "$RCLONE_REMOTE/full/" "$WORKDIR/full/" --include "$base.*"
  rclone copy "$RCLONE_REMOTE/binlog/$HOST_TAG/" "$WORKDIR/binlog/"
fi
[[ -f "$WORKDIR/full/$FULL_BACKUP" ]] || die "本地没有 $WORKDIR/full/$FULL_BACKUP"

if [[ -f "$WORKDIR/full/$FULL_BACKUP.sha256" ]]; then
  if command -v sha256sum >/dev/null; then
    (cd "$WORKDIR/full" && sha256sum -c "$FULL_BACKUP.sha256")
  else
    (cd "$WORKDIR/full" && shasum -a 256 -c "$FULL_BACKUP.sha256")
  fi
else
  log "警告：没有 sha256 校验文件，跳过校验"
fi

# ---------- 3. 找到全备对应的 binlog 起点 ----------
pos_line="$(gzip -dc "$WORKDIR/full/$FULL_BACKUP" | head -n 60 | grep -m1 -o "SOURCE_LOG_FILE='[^']*', SOURCE_LOG_POS=[0-9]*" || true)"
[[ -n "$pos_line" ]] || die "全备里没找到 SOURCE_LOG_FILE（备份时没加 --source-data？）"
start_file="$(echo "$pos_line" | awk -F"'" '{print $2}')"
start_pos="$(echo "$pos_line" | awk -F'SOURCE_LOG_POS=' '{print $2}')"
log "binlog 起点：$start_file 位置 $start_pos"

# 起点文件及之后的所有 binlog，按文件名排序（binlog.000012 这种格式按字符串排序就是时间顺序）
binlogs=()
for p in "$WORKDIR"/binlog/*.[0-9][0-9][0-9][0-9][0-9][0-9]; do
  [[ -f "$p" ]] || continue
  f="${p##*/}"
  [[ "$f" < "$start_file" ]] && continue
  binlogs+=("$f")
done
[[ "${#binlogs[@]}" -gt 0 && "${binlogs[0]}" == "$start_file" ]] \
  || die "binlog 不连续：起点文件 $start_file 不在 $WORKDIR/binlog 里（检查上传任务是否正常）"
log "需要重放的 binlog：${binlogs[*]}"

# ---------- 4. 准备临时实例 ----------
if [[ "$RESTORE_MODE" == "docker" ]]; then
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    die "容器 $CONTAINER 已存在。确认不用了再删除：docker rm -f $CONTAINER"
  fi
  log "启动临时实例 ${DOCKER_IMAGE}，端口 $RESTORE_PORT"
  docker run -d --name "$CONTAINER" \
    -e MYSQL_ROOT_PASSWORD="$RESTORE_ROOT_PASSWORD" \
    -p "$RESTORE_PORT:3306" \
    -v "$WORKDIR:/backup:ro" \
    "$DOCKER_IMAGE" \
    --gtid-mode=ON --enforce-gtid-consistency=ON --skip-log-bin >/dev/null
  # 镜像初始化时会先起一个不监听 TCP 的临时进程，等 TCP 能连上才算真正就绪
  for _ in $(seq 1 90); do
    if docker exec -e MYSQL_PWD="$RESTORE_ROOT_PASSWORD" "$CONTAINER" \
        mysql -uroot -h127.0.0.1 -N -e 'SELECT 1' >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  docker exec -e MYSQL_PWD="$RESTORE_ROOT_PASSWORD" "$CONTAINER" mysql -uroot -h127.0.0.1 -N -e 'SELECT VERSION()' \
    || die "临时实例没有就绪：docker logs $CONTAINER"
  rmysql() { docker exec -i -e MYSQL_PWD="$RESTORE_ROOT_PASSWORD" "$CONTAINER" mysql -uroot -h127.0.0.1 "$@"; }
  # 写作时的 mysql:8.4 官方镜像里已经没有 mysqlbinlog。镜像里有就用镜像里的，没有就用本机的
  if docker exec "$CONTAINER" sh -c 'command -v mysqlbinlog' >/dev/null 2>&1; then
    rbinlog() { docker exec "$CONTAINER" mysqlbinlog --no-defaults "$@"; }
    binlog_path=/backup/binlog
    # 容器里是 UTC 时区，mysqlbinlog 按它所在环境的时区解释 --stop-datetime，所以先换算成 UTC
    if [[ -n "$STOP_DATETIME" ]]; then
      stop_for_binlog="$(date -u -d "$STOP_DATETIME" '+%F %T')"
    fi
  elif command -v mysqlbinlog >/dev/null; then
    rbinlog() { mysqlbinlog --no-defaults "$@"; }
    binlog_path="$WORKDIR/binlog"
    stop_for_binlog="$STOP_DATETIME"
  else
    die "镜像和本机都没有 mysqlbinlog。在本机装 MySQL 官方 APT 源的 mysql-community-server-core（只装程序，不会启动 mysqld），版本不低于源库"
  fi
  log "mysqlbinlog：$(rbinlog --version | head -n 1)"
else
  read -r -a local_args <<< "$LOCAL_MYSQL"
  rmysql() { mysql "${local_args[@]}" "$@"; }
  # --no-defaults：不读 my.cnf，[client] 里的 default-character-set 等选项会让 mysqlbinlog 报错退出
  rbinlog() { mysqlbinlog --no-defaults "$@"; }
  binlog_path="$WORKDIR/binlog"
  stop_for_binlog="$STOP_DATETIME"
fi

# 临时实例必须是空的：清掉它自己的 GTID 记录，否则导入全备时设置 GTID_PURGED 会失败
if [[ "$(rmysql -N -e "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='mall'")" != "0" ]]; then
  die "临时实例里已经有 mall 库，换一个空实例"
fi
rmysql -e 'RESET BINARY LOGS AND GTIDS'

# ---------- 5. 导入全备 ----------
log "导入全备……"
gzip -dc "$WORKDIR/full/$FULL_BACKUP" | rmysql
log "全备导入完成：orders 表 $(rmysql -N -e 'SELECT COUNT(*) FROM mall.orders') 行"

# ---------- 6. 重放 binlog ----------
args=(--start-position="$start_pos")
if [[ -n "$STOP_DATETIME" ]]; then
  args+=(--stop-datetime="$stop_for_binlog")
  log "重放 binlog 到 $STOP_DATETIME 之前（mysqlbinlog 参数时间：${stop_for_binlog}）"
fi
if [[ -n "$EXCLUDE_GTIDS" ]]; then
  args+=(--exclude-gtids="$EXCLUDE_GTIDS")
  log "重放时跳过事务：$EXCLUDE_GTIDS"
fi
paths=()
for f in "${binlogs[@]}"; do paths+=("$binlog_path/$f"); done
# 所有 binlog 必须在一次 mysqlbinlog 调用里重放（跨文件的事务、临时表才不会出错）；
# --start-position 只对第一个文件生效
rbinlog "${args[@]}" "${paths[@]}" | rmysql
log "binlog 重放完成"

# ---------- 7. 核对 ----------
log "恢复结果（核对后再决定导回哪些数据）："
rmysql -t -e "SELECT COUNT(*) AS orders, MAX(id) AS max_order_id, MAX(created_at) AS last_order_at FROM mall.orders; SELECT id, name, stock FROM mall.products ORDER BY id;"
if [[ "$RESTORE_MODE" == "docker" ]]; then
  cat <<EOF

临时实例：127.0.0.1:${RESTORE_PORT}（root / ${RESTORE_ROOT_PASSWORD}），容器名 ${CONTAINER}
导出被误删的表：
  docker exec -e MYSQL_PWD='${RESTORE_ROOT_PASSWORD}' ${CONTAINER} mysqldump -uroot -h127.0.0.1 --single-transaction --set-gtid-purged=OFF mall orders > orders-restored.sql
用完删除：docker rm -f ${CONTAINER}
EOF
fi
