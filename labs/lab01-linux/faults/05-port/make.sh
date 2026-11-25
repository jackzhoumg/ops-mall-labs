#!/usr/bin/env bash
# 故障 5：端口不通。两种原因任选一种：
#   firewall  firewalld 没放行 8080
#   bind      服务只监听在 127.0.0.1，外面访问不到
# 用法：sudo bash make.sh firewall|bind
# 对应教程：Lab 01 第 5.5 节 故障 5
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

require_root
require_deployed
mode=${1:-}

case "${mode}" in
  firewall)
    firewall-cmd --state >/dev/null 2>&1 || die "firewalld 没有运行，这个场景需要 firewalld（systemctl start firewalld）"
    firewall-cmd --quiet --permanent --remove-port=8080/tcp || true
    firewall-cmd --quiet --reload
    ;;
  bind)
    set_env MALL_LISTEN "127.0.0.1:8080"
    restart_service
    wait_healthy || die "mall-api 没起来，先 systemctl status mall-api 看看"
    ;;
  *)
    die "用法：sudo bash make.sh firewall|bind"
    ;;
esac

info "故障已制造：在 lab-web1 上 curl 127.0.0.1:8080/healthz 是好的，但从你的电脑访问 192.168.56.11:8080 不通。"
info "现在开始排查：在你的电脑上和 lab-web1 上分别看什么？"
