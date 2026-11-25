#!/usr/bin/env bash
# 故障 4 恢复：三种原因一起修掉（不管之前制造的是哪种）。
# 对应教程：Lab 01 第 5.5 节 故障 4
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

require_root
require_deployed

set_env MALL_LISTEN ":8080"
chmod 0755 "${BIN}"
systemctl stop lab01-squatter.service 2>/dev/null || true
systemctl reset-failed lab01-squatter.service 2>/dev/null || true
restart_service
if wait_healthy; then
  info "已恢复：mall-api 正常监听 :8080"
  ss -lntp | grep ':8080 ' || true
else
  die "mall-api 还是没起来，journalctl -u mall-api -n 30 看原因"
fi
