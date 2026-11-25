#!/usr/bin/env bash
# lib.sh：故障演练脚本的公共函数，由各目录下的 make.sh / fix.sh source，不单独执行。
# 对应教程：Lab 01 第 5.5 节。

ENV_FILE=/etc/mall-api/mall-api.env
SERVICE=mall-api.service
BIN=/opt/mall-api/mall-api
API=http://127.0.0.1:8080

info() { printf '\033[32m[lab01]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[lab01]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[lab01]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    die "请用 root 或 sudo 执行"
  fi
}

# 检查 mall-api 已按教程 5.2 节部署好
require_deployed() {
  [[ -f ${ENV_FILE} ]] || die "没找到 ${ENV_FILE}，先按教程 5.2 节部署 mall-api"
  [[ -f ${BIN} ]] || die "没找到 ${BIN}，先按教程 5.2 节部署 mall-api"
  systemctl cat "${SERVICE}" >/dev/null 2>&1 || die "没找到 ${SERVICE}，先按教程 5.2 节部署 mall-api"
}

# 第一次改环境变量文件前备份一份，方便手工对比
backup_env() {
  if [[ ! -f ${ENV_FILE}.lab01.bak ]]; then
    cp -a "${ENV_FILE}" "${ENV_FILE}.lab01.bak"
  fi
}

# set_env KEY VALUE：修改（或追加）环境变量文件里的一行。VALUE 里不要有 | 和 &
set_env() {
  local key=$1 val=$2
  backup_env
  if grep -q "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${val}" >>"${ENV_FILE}"
  fi
}

# 等 /healthz 返回 200，最多等 WAIT_TIMEOUT 秒（默认 20）
wait_healthy() {
  local timeout=${WAIT_TIMEOUT:-20} i
  for ((i = 0; i < timeout; i++)); do
    if curl -fsS -m 2 "${API}/healthz" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

restart_service() {
  systemctl daemon-reload
  systemctl reset-failed "${SERVICE}" >/dev/null 2>&1 || true
  systemctl restart "${SERVICE}"
}
