#!/usr/bin/env bash
# 故障 3：磁盘写满 + 「删了文件空间不释放」。
# 在数据盘（默认 /data，教程 5.3 节用 LVM 建的）上生成一个占满空间的「日志文件」，
# 并启动一个一直打开着它的进程（模拟还在写日志的程序）。
# 用法：sudo bash make.sh            # 默认写满 /data
#       sudo LAB_DISK_DIR=/data bash make.sh
# 为了安全，只允许写独立挂载的数据盘，不会写根分区。
# 对应教程：Lab 01 第 5.5 节 故障 3
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

require_root
DIR=${LAB_DISK_DIR:-/data}
PIDFILE=/run/lab01-disk-writer.pid
FILE=${DIR}/logs/mall-access.log

mountpoint -q "${DIR}" || die "${DIR} 不是独立挂载点。先按教程 5.3 节建好 LVM 并挂载到 /data"
[[ ${DIR} != / ]] || die "不允许写满根分区"

mkdir -p "${DIR}/logs"
# 已经做过一次的话先清理掉旧的
if [[ -f ${PIDFILE} ]]; then
  kill "$(cat "${PIDFILE}")" 2>/dev/null || true
  rm -f "${PIDFILE}"
fi
rm -f "${FILE}"

# 剩余空间（KB）减 1M，用 fallocate 一次性占满（比 dd 快，真实占用块）
avail_kb=$(df --output=avail -k "${DIR}" | tail -n 1 | tr -d ' ')
(( avail_kb > 2048 )) || die "${DIR} 剩余空间太少（${avail_kb}KB），先清理一下"
fallocate -l "$(( avail_kb - 1024 ))K" "${FILE}"
# 把剩下的一点也写满
dd if=/dev/zero of="${DIR}/logs/.fill" bs=1M count=2 status=none 2>/dev/null || true

# 模拟一个一直打开着日志文件的程序。sleep 3>&- 让子进程不继承这个文件描述符
# shellcheck disable=SC2016 # $1 要在子 shell 里展开
setsid nohup bash -c 'exec 3>>"$1"; while :; do sleep 3600 3>&-; done' lab01-log-writer "${FILE}" >/dev/null 2>&1 &
echo $! >"${PIDFILE}"

info "故障已制造：告警「lab-web1 ${DIR} 使用率 100%」，往 ${DIR} 写文件报 No space left on device。"
info "现在开始排查：是什么把空间吃满了？删掉之后空间真的回来了吗？"
