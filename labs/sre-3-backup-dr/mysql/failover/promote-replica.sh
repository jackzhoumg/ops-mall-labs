#!/usr/bin/env bash
# 手动故障切换第 1 步：把从库（lab-db2）提升为主库。
# 前提：已经确认旧主库真的不可用，并且已经隔离（停掉 mysqld 或者拦掉 3306），防止两边同时写（脑裂）。
#
# 用法（lab-db2，root 账号写在 ~/.my.cnf）：
#   bash mysql/failover/promote-replica.sh
#
# 做的事：
#   1. 等 SQL 线程把已经收到的 relay log 全部执行完（不丢已经传过来的事务）
#   2. STOP REPLICA + RESET REPLICA ALL（不再从旧主库复制）
#   3. 关闭只读（SET PERSIST，重启后也生效）
# 之后要做的（脚本最后会提示）：改 K8s 的 mysql EndpointSlice、验证写入、处理旧主库。
set -euo pipefail

MYSQL_ARGS="${MYSQL_ARGS:---defaults-extra-file=$HOME/.my.cnf}"
WAIT_SECONDS="${WAIT_SECONDS:-60}"
read -r -a margs <<< "$MYSQL_ARGS"
q() { mysql "${margs[@]}" -N -B -e "$1"; }

log() { echo "$(date '+%F %T') [promote] $*"; }

status="$(mysql "${margs[@]}" -e 'SHOW REPLICA STATUS\G')"
if [[ -z "$status" ]]; then
  log "这台不是从库（SHOW REPLICA STATUS 为空），不需要提升"
  exit 1
fi
echo "$status" | grep -E 'Source_Host|Replica_IO_Running|Replica_SQL_Running:|Seconds_Behind_Source|Retrieved_Gtid_Set|Executed_Gtid_Set' | sed 's/^ */  /'

echo
read -r -p "确认旧主库已经不可用并且已经隔离（不会再接受写入）？输入 yes 继续：" ans
[[ "$ans" == "yes" ]] || { log "已取消"; exit 1; }

# 1. 等已收到的事务执行完
retrieved="$(echo "$status" | awk -F': ' '/Retrieved_Gtid_Set/ {print $2}' | tr -d ' ')"
if [[ -n "$retrieved" ]]; then
  log "等待 relay log 执行完：${retrieved}（最多 ${WAIT_SECONDS} 秒）"
  r="$(q "SELECT WAIT_FOR_EXECUTED_GTID_SET('${retrieved}', ${WAIT_SECONDS})")"
  if [[ "$r" != "0" ]]; then
    log "等待超时，还有事务没执行完。查 SHOW REPLICA STATUS 里的 Last_SQL_Error，处理后再执行"
    exit 1
  fi
fi

# 2. 断开复制
q 'STOP REPLICA'
q 'RESET REPLICA ALL'
log "已停止复制并清除复制配置"

# 3. 可写
q 'SET PERSIST super_read_only = OFF'
q 'SET PERSIST read_only = OFF'
log "已关闭只读：read_only=$(q 'SELECT @@read_only') super_read_only=$(q 'SELECT @@super_read_only')"

log "当前 gtid_executed：$(q 'SELECT @@gtid_executed' | tr -d '\n')"
cat <<'EOF'

下一步：
  1. k8s-master：kubectl apply -f k8s/mysql-endpointslice-db2.yaml   （mall-api 改连 lab-db2）
  2. 验证：curl -s -XPOST -H 'Content-Type: application/json' -d '{"product_id":1,"quantity":1}' http://mall.lab.local/api/orders
  3. 还在用 Lab 02 虚拟机部署（lab-web1/2）的话，把它们的 MALL_DB_DSN 也改成 192.168.56.14 并重启 mall-api
  4. 旧主库恢复后，不要直接启动对外服务：先按教程用 rejoin-as-replica.sh 降级成从库
EOF
