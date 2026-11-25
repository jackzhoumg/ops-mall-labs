#!/usr/bin/env bash
# Lab 09：在虚拟机上安装 node_exporter / mysqld_exporter / redis_exporter（二进制 + systemd）
#
# 用法（root 执行）：
#   ./install-exporters.sh node                                   # lab-web1 lab-web2 lab-db1 lab-db2 都装
#   MYSQL_EXPORTER_PASSWORD='xxx' ./install-exporters.sh mysqld   # lab-db1 lab-db2
#   REDIS_PASSWORD='xxx' ./install-exporters.sh redis             # lab-db1，Redis 没设密码就不传
#
# 可选环境变量：
#   NODE_EXPORTER_VERSION / MYSQLD_EXPORTER_VERSION / REDIS_EXPORTER_VERSION  覆盖默认版本
#   GITHUB_MIRROR   GitHub 下载加速前缀，例如 https://你们自建的代理/ ，会拼在 https://github.com 前面
#   LOCAL_DIR       离线安装：提前把 tar.gz 放进这个目录，再把各项目 Release 页的 sha256sums.txt
#                   内容合并成一个 sha256sums.txt 放在同一目录，脚本不再联网下载
#   ALLOW_CIDR      防火墙放行的来源网段，默认 192.168.56.0/24
#
# 写作时版本：node_exporter 1.13.1、mysqld_exporter 0.21.0、redis_exporter 1.99.0，以 GitHub Releases 为准。
set -euo pipefail

NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.13.1}"
MYSQLD_EXPORTER_VERSION="${MYSQLD_EXPORTER_VERSION:-0.21.0}"
REDIS_EXPORTER_VERSION="${REDIS_EXPORTER_VERSION:-1.99.0}"
GITHUB_MIRROR="${GITHUB_MIRROR:-}"
LOCAL_DIR="${LOCAL_DIR:-}"
ALLOW_CIDR="${ALLOW_CIDR:-192.168.56.0/24}"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,17p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
  exit 1
}

[[ $# -eq 1 ]] || usage
[[ $EUID -eq 0 ]] || die "请用 root 执行（sudo -i 或 sudo $0 $1）"

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) die "不支持的 CPU 架构：$(uname -m)" ;;
esac

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# fetch <下载目录 URL> <文件名>：下载（或从 LOCAL_DIR 复制）文件并用 sha256sums.txt 校验
fetch() {
  local base_url="$1" file="$2"
  if [[ -n "$LOCAL_DIR" ]]; then
    log "从 $LOCAL_DIR 复制 $file"
    cp "$LOCAL_DIR/$file" "$WORKDIR/"
    cp "$LOCAL_DIR/sha256sums.txt" "$WORKDIR/"
  else
    log "下载 $base_url/$file"
    curl -fL --retry 3 --connect-timeout 10 -o "$WORKDIR/$file" "$base_url/$file"
    curl -fL --retry 3 --connect-timeout 10 -o "$WORKDIR/sha256sums.txt" "$base_url/sha256sums.txt"
  fi
  (cd "$WORKDIR" && grep " ${file}\$" sha256sums.txt | sha256sum -c -) || die "$file 校验失败，文件可能不完整或被篡改"
}

# ensure_user <用户名>：创建不能登录的系统用户，exporter 不用 root 跑
ensure_user() {
  id "$1" &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin "$1"
}

# open_port <端口>：ufw 已启用时，只对实验网段放行。
# ufw 没启用就不动它：远程登录的机器上贸然 ufw enable，没先放行 22 端口会把自己锁在外面。
open_port() {
  local port="$1"
  if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow from "$ALLOW_CIDR" to any port "$port" proto tcp >/dev/null
    log "ufw 已放行 ${ALLOW_CIDR} -> ${port}/tcp"
  else
    log "ufw 未启用，跳过防火墙配置"
  fi
}

# write_unit <服务名> <运行用户> <ExecStart> [EnvironmentFile]
write_unit() {
  local name="$1" user="$2" exec_start="$3" env_file="${4:-}"
  {
    echo "[Unit]"
    echo "Description=Prometheus ${name}"
    echo "After=network-online.target"
    echo "Wants=network-online.target"
    echo
    echo "[Service]"
    echo "User=${user}"
    echo "Group=${user}"
    [[ -n "$env_file" ]] && echo "EnvironmentFile=${env_file}"
    echo "ExecStart=${exec_start}"
    echo "Restart=on-failure"
    echo "RestartSec=5"
    echo "NoNewPrivileges=yes"
    echo "ProtectSystem=strict"
    echo "ProtectHome=read-only"
    echo "PrivateTmp=yes"
    echo
    echo "[Install]"
    echo "WantedBy=multi-user.target"
  } >"/etc/systemd/system/${name}.service"
  systemctl daemon-reload
  systemctl enable --now "${name}.service"
  systemctl restart "${name}.service"
}

# wait_metrics <端口> <要出现的指标名>
wait_metrics() {
  local port="$1" metric="$2"
  local body
  for _ in $(seq 1 10); do
    # 先存到变量再 grep：直接 curl | grep -q 在 pipefail 下可能因为 SIGPIPE 误判失败
    body="$(curl -fs "http://127.0.0.1:${port}/metrics" || true)"
    if grep -q "^${metric}" <<<"$body"; then
      log "验证通过：curl http://127.0.0.1:${port}/metrics 能看到 ${metric}"
      return 0
    fi
    sleep 1
  done
  die "端口 ${port} 上没看到 ${metric}，用 journalctl -u 对应服务名 -n 50 查原因"
}

install_node() {
  local v="$NODE_EXPORTER_VERSION" pkg="node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}"
  fetch "${GITHUB_MIRROR}https://github.com/prometheus/node_exporter/releases/download/v${v}" "${pkg}.tar.gz"
  tar -xzf "$WORKDIR/${pkg}.tar.gz" -C "$WORKDIR"
  install -m 0755 "$WORKDIR/${pkg}/node_exporter" /usr/local/bin/node_exporter
  ensure_user node_exporter
  # 排除虚拟文件系统、snap 和容器运行时的挂载点，减少无用的时间序列
  write_unit node_exporter node_exporter \
    "/usr/local/bin/node_exporter --web.listen-address=:9100 --collector.filesystem.mount-points-exclude=^/(dev|proc|run|sys|snap|var/lib/docker|var/lib/containers)(\$\$|/)"
  open_port 9100
  wait_metrics 9100 node_cpu_seconds_total
}

install_mysqld() {
  [[ -n "${MYSQL_EXPORTER_PASSWORD:-}" ]] || die "请先在 MySQL 里建 exporter 账号（见 mysql-exporter-user.sql），再用 MYSQL_EXPORTER_PASSWORD 传入密码"
  local v="$MYSQLD_EXPORTER_VERSION" pkg="mysqld_exporter-${MYSQLD_EXPORTER_VERSION}.linux-${ARCH}"
  fetch "${GITHUB_MIRROR}https://github.com/prometheus/mysqld_exporter/releases/download/v${v}" "${pkg}.tar.gz"
  tar -xzf "$WORKDIR/${pkg}.tar.gz" -C "$WORKDIR"
  install -m 0755 "$WORKDIR/${pkg}/mysqld_exporter" /usr/local/bin/mysqld_exporter
  ensure_user mysqld_exporter
  # 从 0.15.0 起不再支持 DATA_SOURCE_NAME 环境变量，账号密码写在 my.cnf 格式的文件里
  install -d -m 0750 -o root -g mysqld_exporter /etc/mysqld_exporter
  umask 027
  cat >/etc/mysqld_exporter/my.cnf <<EOF
[client]
user=exporter
password=${MYSQL_EXPORTER_PASSWORD}
host=127.0.0.1
port=3306
EOF
  chown root:mysqld_exporter /etc/mysqld_exporter/my.cnf
  chmod 0640 /etc/mysqld_exporter/my.cnf
  # slave_status 采集器默认就开着，这里显式写出来，提醒大家主从延迟指标从这里来
  write_unit mysqld_exporter mysqld_exporter \
    "/usr/local/bin/mysqld_exporter --config.my-cnf=/etc/mysqld_exporter/my.cnf --web.listen-address=:9104 --collect.slave_status"
  open_port 9104
  wait_metrics 9104 mysql_up
  local body
  body="$(curl -fs http://127.0.0.1:9104/metrics || true)"
  if grep -q '^mysql_up 1' <<<"$body"; then
    log "mysql_up 1：exporter 已连上 MySQL"
  else
    log "注意：mysql_up 不是 1，检查 exporter 账号密码和权限"
  fi
}

install_redis() {
  local v="$REDIS_EXPORTER_VERSION" pkg="redis_exporter-v${REDIS_EXPORTER_VERSION}.linux-${ARCH}"
  fetch "${GITHUB_MIRROR}https://github.com/oliver006/redis_exporter/releases/download/v${v}" "${pkg}.tar.gz"
  tar -xzf "$WORKDIR/${pkg}.tar.gz" -C "$WORKDIR"
  install -m 0755 "$WORKDIR/${pkg}/redis_exporter" /usr/local/bin/redis_exporter
  ensure_user redis_exporter
  # 密码放在只有 root 和 redis_exporter 组能读的环境变量文件里，不出现在 ps 命令行参数中
  install -d -m 0750 -o root -g redis_exporter /etc/redis_exporter
  umask 027
  printf 'REDIS_ADDR=redis://127.0.0.1:6379\nREDIS_PASSWORD=%s\n' "${REDIS_PASSWORD:-}" >/etc/redis_exporter/env
  chown root:redis_exporter /etc/redis_exporter/env
  chmod 0640 /etc/redis_exporter/env
  write_unit redis_exporter redis_exporter \
    "/usr/local/bin/redis_exporter --web.listen-address=:9121" /etc/redis_exporter/env
  open_port 9121
  wait_metrics 9121 redis_up
}

case "$1" in
  node) install_node ;;
  mysqld) install_mysqld ;;
  redis) install_redis ;;
  *) usage ;;
esac
log "完成"
