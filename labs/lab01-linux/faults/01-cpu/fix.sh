#!/usr/bin/env bash
# 故障 1 恢复：结束请求、重启 mall-api（handler 不会因为客户端断开而停下）、关闭 MALL_DEBUG。
# 对应教程：Lab 01 第 5.5 节 故障 1
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

require_root
require_deployed

pkill -f "api/debug/cpu" || true
set_env MALL_DEBUG false
restart_service
if wait_healthy; then
  info "已恢复：mall-api 已重启，MALL_DEBUG=false。用 top 确认 CPU 降下来了。"
else
  die "mall-api 没起来，systemctl status mall-api 看原因"
fi
