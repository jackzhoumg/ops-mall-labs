#!/usr/bin/env bash
# 故障 3 恢复：停掉占着文件的进程、删除占空间的文件。
# 对应教程：Lab 01 第 5.5 节 故障 3
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

require_root
DIR=${LAB_DISK_DIR:-/data}
PIDFILE=/run/lab01-disk-writer.pid

if [[ -f ${PIDFILE} ]]; then
  kill "$(cat "${PIDFILE}")" 2>/dev/null || true
  rm -f "${PIDFILE}"
fi
pkill -f lab01-log-writer || true
rm -f "${DIR}/logs/mall-access.log" "${DIR}/logs/.fill"
sleep 1
info "已恢复，当前 ${DIR} 使用情况："
df -h "${DIR}"
info "lsof +L1 里不应再有 ${DIR} 下的文件"
