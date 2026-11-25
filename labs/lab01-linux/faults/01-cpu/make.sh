#!/usr/bin/env bash
# 故障 1：CPU 飙高。打开 MALL_DEBUG，让一个请求把所有 CPU 核占满约 3 分钟。
# 用法：sudo bash make.sh [秒数，默认 180，最大 300]
# 对应教程：Lab 01 第 5.5 节 故障 1
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

require_root
require_deployed
secs=${1:-180}

set_env MALL_DEBUG true
restart_service
wait_healthy || die "mall-api 没起来，先 systemctl status mall-api 看看"

# 模拟「某个接口被调用后把 CPU 吃满」。setsid + nohup：脚本退出、SSH 断开后请求还在
setsid nohup curl -s -m $((secs + 30)) "${API}/api/debug/cpu?seconds=${secs}" >/dev/null 2>&1 &

info "故障已制造：用户反馈商城「很卡」，监控显示 lab-web1 CPU 使用率 100%。"
info "现在开始排查：是谁在吃 CPU？从什么时候开始的？怎么止损？"
