#!/usr/bin/env bash
# 故障 2 恢复：删掉内存上限、关闭 MALL_DEBUG、重启 mall-api。
# 对应教程：Lab 01 第 5.5 节 故障 2
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

require_root
require_deployed

rm -f /etc/systemd/system/mall-api.service.d/90-lab01-memory.conf
rmdir /etc/systemd/system/mall-api.service.d 2>/dev/null || true
set_env MALL_DEBUG false
restart_service
if wait_healthy; then
  info "已恢复：内存上限已去掉，MALL_DEBUG=false。"
  info "systemctl show mall-api -p MemoryMax 应显示 MemoryMax=infinity"
else
  die "mall-api 没起来，systemctl status mall-api 看原因"
fi
