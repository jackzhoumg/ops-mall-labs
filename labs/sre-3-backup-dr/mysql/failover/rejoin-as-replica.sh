#!/usr/bin/env bash
# 故障切换之后：让修好的旧主库（lab-db1）以从库身份重新加入，复制新主库（lab-db2）。
#
# 用法（lab-db1，mysqld 已启动，root 账号写在 ~/.my.cnf）：
#   NEW_SOURCE=192.168.56.14 REPL_USER=repl REPL_PASSWORD='复制账号密码' bash mysql/failover/rejoin-as-replica.sh
#
# 安全检查：如果旧主库上有新主库没有的事务（切换时还没传过去的那部分，叫 errant transaction），
# 直接加入复制会导致数据不一致甚至复制报错。脚本发现这种情况会停下来，需要人工处理：
#   - 把这些事务的数据导出来，人工核对后补到新主库；或者
#   - 放弃这台机器的数据，用全备 + binlog 重建从库。
set -euo pipefail

NEW_SOURCE="${NEW_SOURCE:-192.168.56.14}"
NEW_SOURCE_PORT="${NEW_SOURCE_PORT:-3306}"
REPL_USER="${REPL_USER:-repl}"
REPL_PASSWORD="${REPL_PASSWORD:?需要 REPL_PASSWORD（Lab 02 配主从时建的复制账号密码）}"
MYSQL_ARGS="${MYSQL_ARGS:---defaults-extra-file=$HOME/.my.cnf}"
read -r -a margs <<< "$MYSQL_ARGS"
q() { mysql "${margs[@]}" -N -B -e "$1"; }
# 用复制账号连新主库，只读一个系统变量，不需要额外权限
qs() { MYSQL_PWD="$REPL_PASSWORD" mysql --no-defaults -h "$NEW_SOURCE" -P "$NEW_SOURCE_PORT" -u "$REPL_USER" -N -B -e "$1"; }
log() { echo "$(date '+%F %T') [rejoin] $*"; }

# 1. 先只读，防止有程序还连着这台机器写
q 'SET PERSIST super_read_only = ON'
log "本机已设为只读"

# 2. 检查 errant transaction
mine="$(q "SELECT REPLACE(@@gtid_executed, CHAR(10), '')")"
theirs="$(qs "SELECT REPLACE(@@gtid_executed, CHAR(10), '')")"
errant="$(q "SELECT GTID_SUBTRACT('${mine}', '${theirs}')")"
if [[ -n "$errant" ]]; then
  log "发现只在本机执行过、新主库没有的事务：${errant}"
  log "这是切换时丢失的数据。先用 mysql/find-binlog-event.sh 或 mysqlbinlog --include-gtids='${errant}' 查看内容，处理完再加入复制"
  exit 1
fi
log "没有多余事务，可以安全加入复制"

# 3. 配置复制（GTID 自动定位，不用找 binlog 位点）
q "CHANGE REPLICATION SOURCE TO SOURCE_HOST='${NEW_SOURCE}', SOURCE_PORT=${NEW_SOURCE_PORT}, SOURCE_USER='${REPL_USER}', SOURCE_PASSWORD='${REPL_PASSWORD}', SOURCE_AUTO_POSITION=1, GET_SOURCE_PUBLIC_KEY=1"
q 'START REPLICA'
sleep 3
status="$(mysql "${margs[@]}" -e 'SHOW REPLICA STATUS\G')"
echo "$status" | grep -E 'Source_Host|Replica_IO_Running|Replica_SQL_Running:|Seconds_Behind_Source|Last_IO_Error:|Last_SQL_Error:' | sed 's/^ */  /'
if ! echo "$status" | grep -q 'Replica_IO_Running: Yes' || ! echo "$status" | grep -q 'Replica_SQL_Running: Yes'; then
  # 常见原因：复制账号密码不对、新主库没开 binlog（log_bin=OFF，没法当复制源）、防火墙没放 3306
  log "复制没有正常运行，看上面的 Last_IO_Error / Last_SQL_Error"
  exit 1
fi
log "完成。Seconds_Behind_Source 降到 0 才算追上新主库"
