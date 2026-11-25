#!/usr/bin/env bash
# 误删恢复辅助脚本：全备 + binlog 时间点恢复（PITR）
# 只生成 SQL 文件，不自动执行。恢复是高危操作，生成后人工检查再导入
#
# 用法（lab-db1 主库上，root 执行）：
#   sudo bash mysql_pitr.sh start-pos <全备.sql.gz>
#       打印全备对应的 binlog 起点（文件名和位置）
#   sudo bash mysql_pitr.sh find-drop [binlog 文件...]
#       在 binlog 里找 DROP / TRUNCATE 语句，打印所在文件、事务起始位置、GTID、时间
#       不给文件就扫 /var/lib/mysql/mysql-bin.[0-9]* 全部
#   sudo bash mysql_pitr.sh extract <全备.sql.gz> <停止文件> <停止位置>
#       生成两个文件到 OUT_DIR（默认 /data/backup/pitr）：
#         restore-full.sql    全备解压，去掉 SQL_LOG_BIN=0 和 GTID_PURGED 两类语句
#         replay-binlog.sql   从全备位置回放到“停止位置”之前（不含误操作那个事务）
#
# 为什么要去掉 SQL_LOG_BIN / GTID_PURGED、为什么 mysqlbinlog 要加 --skip-gtids，见教程 5.7 节
# 对应教程：Lab 02 商城上线 5.7 节
set -Eeuo pipefail

BINLOG_DIR="${BINLOG_DIR:-/var/lib/mysql}"
BINLOG_BASENAME="${BINLOG_BASENAME:-mysql-bin}"
OUT_DIR="${OUT_DIR:-/data/backup/pitr}"

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

die() {
  echo "错误：$*" >&2
  exit 1
}

# 从全备里读出 binlog 起点，输出 "文件名 位置"
start_pos() {
  local dump="$1" line
  [[ -r "$dump" ]] || die "读不到全备文件 ${dump}"
  # 起点在文件开头几十行内；gzip 被 grep -m1 提前关掉管道会收到 SIGPIPE，用 || true 屏蔽
  line=$({ gzip -cd "$dump" 2>/dev/null || true; } | grep -m1 -E "^-- CHANGE (REPLICATION SOURCE|MASTER) TO" || true)
  [[ -n "$line" ]] || die "${dump} 里找不到 binlog 位置，备份时是不是没加 --source-data=2？"
  local file pos
  file=$(sed -E "s/.*_LOG_FILE='([^']+)'.*/\1/" <<<"$line")
  pos=$(sed -E "s/.*_LOG_POS=([0-9]+).*/\1/" <<<"$line")
  echo "$file $pos"
}

list_binlogs() {
  local f
  for f in "${BINLOG_DIR}/${BINLOG_BASENAME}".[0-9]*; do
    [[ -f "$f" ]] && echo "$f"
  done | sort
}

find_drop() {
  local files=("$@")
  if (( ${#files[@]} == 0 )); then
    mapfile -t files < <(list_binlogs)
  fi
  (( ${#files[@]} > 0 )) || die "${BINLOG_DIR} 下没有 binlog 文件"
  local f
  printf '%-22s %-10s %-50s %s\n' "binlog 文件" "事务起点" "GTID" "时间 / 语句"
  for f in "${files[@]}"; do
    # 每个事务以 GTID 事件开头，"# at N" 是事件起始位置。
    # 停止位置要用误操作那个事务的 GTID 事件起点，这样整个事务都不回放
    mysqlbinlog --base64-output=decode-rows "$f" | awk -v file="$(basename "$f")" -v q="'" '
      /^# at [0-9]+/ { at = $3; next }
      /end_log_pos .*[ \t]GTID[ \t]/ { gtid_at = at; ts = $1 " " $2; sub(/^#/, "", ts); next }
      /SET @@SESSION.GTID_NEXT=/ { g = $0; sub(/.*GTID_NEXT= */, "", g); sub(/\/\*.*/, "", g); gsub(q, "", g); gtid = g; next }
      toupper($0) ~ /^(DROP|TRUNCATE) / { printf "%-22s %-10s %-50s %s  %s\n", file, gtid_at, gtid, ts, $0 }
    '
  done
}

extract() {
  local dump="$1" stop_file="$2" stop_pos="$3"
  [[ "$stop_pos" =~ ^[0-9]+$ ]] || die "停止位置必须是数字：${stop_pos}"
  local sp start_file start
  sp=$(start_pos "$dump")
  read -r start_file start <<<"$sp"
  [[ -f "${BINLOG_DIR}/${start_file}" ]] || die "全备起点的 binlog ${start_file} 已经不在了（被清理？），没法做时间点恢复"
  [[ -f "${BINLOG_DIR}/${stop_file}" ]] || die "找不到 ${BINLOG_DIR}/${stop_file}"
  [[ "$start_file" < "$stop_file" || "$start_file" == "$stop_file" ]] || die "停止文件 ${stop_file} 比起点 ${start_file} 还早"

  # 起点到停止文件之间的所有 binlog，按文件名顺序
  local files=() f name
  while read -r f; do
    name=$(basename "$f")
    if [[ ! "$name" < "$start_file" && ! "$name" > "$stop_file" ]]; then
      files+=("$f")
    fi
  done < <(list_binlogs)

  mkdir -p "$OUT_DIR"
  chmod 700 "$OUT_DIR"
  local full="${OUT_DIR}/restore-full.sql" replay="${OUT_DIR}/replay-binlog.sql"

  # 去掉 SQL_LOG_BIN 和 GTID_PURGED：
  #   SQL_LOG_BIN=0 会让导入不写 binlog，从库就收不到恢复的数据
  #   GTID_PURGED 和本机已有的 GTID 重叠，在原库上导入会直接报错
  gzip -cd "$dump" | sed -e '/SQL_LOG_BIN/d' -e '/^SET @@GLOBAL.GTID_PURGED/d' > "$full"

  # --start-position 作用于第一个文件，--stop-position 作用于最后一个文件
  # --skip-gtids：这些事务的 GTID 本机已经执行过，带着原 GTID 回放会被静默跳过，数据一条都回不来
  mysqlbinlog --skip-gtids \
    --start-position="$start" --stop-position="$stop_pos" \
    "${files[@]}" > "$replay"

  echo "全备起点：${start_file}:${start}"
  echo "回放终点：${stop_file}:${stop_pos}（不含）"
  echo "回放的 binlog：${files[*]##*/}"
  echo
  echo "已生成："
  ls -lh "$full" "$replay"
  echo
  echo "检查 replay-binlog.sql 里没有误操作语句："
  echo "  grep -niE '^(DROP|TRUNCATE) ' ${replay} || echo 没有"
  echo "确认停写后再导入："
  echo "  mysql < ${full} && mysql < ${replay}"
}

main() {
  (( $# >= 1 )) || usage
  command -v mysqlbinlog >/dev/null || die "找不到 mysqlbinlog"
  local cmd="$1"
  shift
  case "$cmd" in
    start-pos)
      (( $# == 1 )) || usage
      start_pos "$1"
      ;;
    find-drop)
      find_drop "$@"
      ;;
    extract)
      (( $# == 3 )) || usage
      extract "$1" "$2" "$3"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
