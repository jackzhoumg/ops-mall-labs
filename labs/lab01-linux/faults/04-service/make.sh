#!/usr/bin/env bash
# 故障 4：mall-api 起不来。四种原因任选一种：
#   config  环境变量文件写错（监听端口写成了不存在的端口号）
#   exec    二进制丢了执行权限（常见于手工 scp 覆盖、解压时权限丢失）
#   dir     二进制有执行权限，但所在目录 mall 用户进不去（目录权限被改成 0700）
#   port    8080 端口被别的进程占了
# 用法：sudo bash make.sh config|exec|dir|port
# 对应教程：Lab 01 第 5.5 节 故障 4
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=SCRIPTDIR/../lib.sh
source "${SCRIPT_DIR}/../lib.sh"

require_root
require_deployed
mode=${1:-}

case "${mode}" in
  config)
    set_env MALL_LISTEN ":80800"
    restart_service || true
    ;;
  exec)
    chmod 0644 "${BIN}"
    restart_service || true
    ;;
  dir)
    chmod 0700 "$(dirname "${BIN}")"
    restart_service || true
    ;;
  port)
    systemctl stop "${SERVICE}"
    systemctl stop lab01-squatter.service 2>/dev/null || true
    systemctl reset-failed lab01-squatter.service 2>/dev/null || true
    # 用一个临时 systemd 单元占住 8080，模拟「别人在这台机器上起了个程序」
    systemd-run --unit=lab01-squatter --quiet python3 -m http.server 8080
    sleep 2
    systemctl start "${SERVICE}" || true
    ;;
  *)
    die "用法：sudo bash make.sh config|exec|dir|port"
    ;;
esac

info "故障已制造：同事改完配置重启了 mall-api，之后接口就不通了。"
info "现在开始排查：服务是什么状态？日志里说了什么？"
