#!/usr/bin/env bash
# 故障 5 恢复：放行 8080、监听地址改回 :8080。
# 对应教程：Lab 01 第 5.5 节 故障 5
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

require_root
require_deployed

if ufw status | grep -q '^Status: active'; then
  ufw allow 8080/tcp >/dev/null
fi
set_env MALL_LISTEN ":8080"
restart_service
if wait_healthy; then
  info "已恢复：在你的电脑上执行 curl http://192.168.56.11:8080/healthz 验证"
  ss -lnt | grep ':8080 ' || true
else
  die "mall-api 没起来，systemctl status mall-api 看原因"
fi
