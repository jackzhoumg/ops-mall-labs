#!/usr/bin/env bash
# 压测数据准备与清理（实验环境用，在 lab-db1 上执行）。
#   prepare：记下当前最大订单号，备份各商品库存，把库存调到 100 万，避免压测中途库存耗尽全变成 409
#   cleanup：删掉压测期间产生的订单，把库存恢复成压测前的值
#
# 用法（lab-db1）：
#   bash scripts/loadtest-data.sh prepare
#   ...压测...
#   bash scripts/loadtest-data.sh cleanup
#
# 生产环境不能这么干：压测订单要写影子库或带压测标记，由业务代码隔离，见教程“压测安全规范”。
#
# 环境变量：
#   MYSQL_CMD  连接 MySQL 的命令，默认 mysql（用 ~/.my.cnf 里的 root 账号，文件权限 600）
#   STATE_DIR  保存压测前状态的目录，默认 /var/tmp/mall-loadtest
set -euo pipefail

MYSQL_CMD="${MYSQL_CMD:-mysql}"
STATE_DIR="${STATE_DIR:-/var/tmp/mall-loadtest}"
read -r -a mysql_cmd <<< "$MYSQL_CMD"

sql() { "${mysql_cmd[@]}" -N -B mall -e "$1"; }

prepare() {
  if [[ -f "$STATE_DIR/marker" ]]; then
    echo "已经 prepare 过（$STATE_DIR/marker 存在），先 cleanup 再重新 prepare" >&2
    exit 1
  fi
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  sql "SELECT COALESCE(MAX(id), 0) FROM orders" > "$STATE_DIR/marker"
  sql "SELECT id, stock FROM products" > "$STATE_DIR/stock.tsv"
  sql "UPDATE products SET stock = 1000000"
  echo "压测前最大订单号：$(cat "$STATE_DIR/marker")，库存已备份到 $STATE_DIR/stock.tsv 并调到 1000000"
}

cleanup() {
  if [[ ! -f "$STATE_DIR/marker" ]]; then
    echo "没找到 $STATE_DIR/marker，没有 prepare 过" >&2
    exit 1
  fi
  local marker deleted
  marker="$(cat "$STATE_DIR/marker")"
  [[ "$marker" =~ ^[0-9]+$ ]] || { echo "marker 内容不是数字：$marker" >&2; exit 1; }
  deleted="$(sql "DELETE FROM orders WHERE id > ${marker}; SELECT ROW_COUNT();")"
  while IFS=$'\t' read -r id stock; do
    [[ "$id" =~ ^[0-9]+$ && "$stock" =~ ^-?[0-9]+$ ]] || continue
    sql "UPDATE products SET stock = ${stock} WHERE id = ${id}"
  done < "$STATE_DIR/stock.tsv"
  rm -f "$STATE_DIR/marker" "$STATE_DIR/stock.tsv"
  echo "已删除压测订单 ${deleted} 条，库存已恢复"
  sql "SELECT id, name, stock FROM products ORDER BY id"
}

case "${1:-}" in
  prepare) prepare ;;
  cleanup) cleanup ;;
  *) echo "用法: $0 prepare|cleanup" >&2; exit 1 ;;
esac
