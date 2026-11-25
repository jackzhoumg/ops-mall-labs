#!/usr/bin/env bash
# 故障 2：内存不足 / OOM。给 mall-api 加 150M 内存上限（MemoryMax），再反复调用 /api/debug/leak 模拟内存泄漏。
# 用法：sudo bash make.sh
# 对应教程：Lab 01 第 5.5 节 故障 2
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

require_root
require_deployed
DROPIN_DIR=/etc/systemd/system/mall-api.service.d
DROPIN=${DROPIN_DIR}/90-lab01-memory.conf

mkdir -p "${DROPIN_DIR}"
cat >"${DROPIN}" <<'CONF'
# Lab 01 故障 2 临时加的内存上限，fix.sh 会删掉这个文件
[Service]
MemoryMax=150M
MemorySwapMax=0
CONF

set_env MALL_DEBUG true
restart_service
wait_healthy || die "mall-api 没起来，先 systemctl status mall-api 看看"

# 每次多占 40M 且不释放，第 4 次左右超过 150M，被内核 OOM Killer 杀掉
for i in 1 2 3 4 5 6; do
  if out=$(curl -fsS -m 10 "${API}/api/debug/leak?mb=40" 2>&1); then
    info "第 ${i} 次请求：${out}"
  else
    warn "第 ${i} 次请求失败：${out}"
    break
  fi
  sleep 1
done

info "故障已制造：用户反馈下单偶尔报错，接口时好时坏。"
info "现在开始排查：进程还在吗？刚才发生了什么？是谁杀了它？"
