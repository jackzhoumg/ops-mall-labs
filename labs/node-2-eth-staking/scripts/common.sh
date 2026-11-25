#!/usr/bin/env bash
# 公共函数：被其他脚本 source，不单独执行。
# shellcheck disable=SC2034  # 变量给 source 它的脚本用
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [[ -f "$COMPOSE_DIR/.env" ]]; then
  # 只读需要的几个变量，不 source 整个 .env（里面的值可能带特殊字符）
  for k in VC_DATA_DIR LIGHTHOUSE_IMAGE; do
    v="$(grep -E "^$k=" "$COMPOSE_DIR/.env" | tail -1 | cut -d= -f2-)"
    if [[ -n "$v" && -z "${!k:-}" ]]; then
      printf -v "$k" '%s' "$v"
    fi
  done
fi
VC_DATA_DIR="${VC_DATA_DIR:-/data/eth/validator}"
LIGHTHOUSE_IMAGE="${LIGHTHOUSE_IMAGE:-sigp/lighthouse:v8.3.3}"
BN="${BN:-http://127.0.0.1:5052}"

vc_running() {
  # 本机 compose 里的 validator 容器是否在运行
  [[ "$(docker inspect -f '{{.State.Running}}' lighthouse-vc 2>/dev/null)" == "true" ]]
}

die() {
  echo "错误：$*" >&2
  exit 1
}

confirm() {
  local ans
  read -r -p "$1 输入 yes 继续：" ans
  [[ "$ans" == "yes" ]] || die "已取消"
}
