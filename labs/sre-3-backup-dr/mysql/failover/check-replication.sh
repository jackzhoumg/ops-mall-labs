#!/usr/bin/env bash
# 切换前后检查本机 MySQL 的角色和复制状态，在 lab-db1、lab-db2 上各跑一次对比。
#
# 用法（lab-db1 / lab-db2，root 账号写在 ~/.my.cnf）：
#   bash mysql/failover/check-replication.sh
#   # 把另一台输出的 gtid_executed 贴进来，算出“只在本机有”的事务：
#   PEER_GTID='3e11fa47-...:1-1234' bash mysql/failover/check-replication.sh
set -uo pipefail

MYSQL_ARGS="${MYSQL_ARGS:---defaults-extra-file=$HOME/.my.cnf}"
PEER_GTID="${PEER_GTID:-}"
read -r -a margs <<< "$MYSQL_ARGS"
q() { mysql "${margs[@]}" -N -B -e "$1"; }

if ! q 'SELECT 1' >/dev/null; then
  echo "连不上本机 MySQL（mysqld 没启动，或者 ~/.my.cnf 不对）"
  exit 1
fi

read -r host ro sro gm <<< "$(q 'SELECT @@hostname, @@read_only, @@super_read_only, @@gtid_mode')"
# -B 模式会把 GTID 集合里的换行输出成字面量 \n，先在 SQL 里去掉换行
gtid="$(q "SELECT REPLACE(@@gtid_executed, CHAR(10), '')")"
echo "主机：${host}  read_only=${ro}  super_read_only=${sro}  gtid_mode=${gm}"
echo "gtid_executed：${gtid}"

status="$(mysql "${margs[@]}" -e 'SHOW REPLICA STATUS\G')"
if [[ -z "$status" ]]; then
  if [[ "$ro" == "0" ]]; then
    echo "角色：主库（可写，没有复制源）"
  else
    echo "角色：只读，但没有配置复制源（可能是刚隔离的旧主库）"
  fi
else
  echo "角色：从库"
  echo "$status" | grep -E 'Source_Host|Replica_IO_Running|Replica_SQL_Running:|Seconds_Behind_Source|Last_IO_Error:|Last_SQL_Error:|Retrieved_Gtid_Set|Auto_Position' \
    | sed 's/^ */  /'
fi

if [[ -n "$PEER_GTID" ]]; then
  only_here="$(q "SELECT GTID_SUBTRACT('${gtid}', '${PEER_GTID}')")"
  only_peer="$(q "SELECT GTID_SUBTRACT('${PEER_GTID}', '${gtid}')")"
  echo "只在本机有的事务：${only_here:-无}"
  echo "只在对方有的事务：${only_peer:-无}"
  echo "（切换后旧主库上 [只在本机有] 的事务，就是这次切换丢失的数据，处理完才能让它重新加入复制）"
fi
