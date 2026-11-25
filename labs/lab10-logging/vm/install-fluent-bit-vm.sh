#!/usr/bin/env bash
# Lab 10：在虚拟机（Ubuntu Server 24.04）上安装 Fluent Bit，把日志推到 K8s 里的 Loki
#
# 用法（root 执行，在本目录下）：
#   ./install-fluent-bit-vm.sh web    # lab-web1、lab-web2：Nginx 访问 / 错误日志 + mall-api 的 journald 日志
#   ./install-fluent-bit-vm.sh db     # lab-db1：MySQL 慢日志 + 错误日志
#
# 前提：hosts 里有 "192.168.56.200 loki.lab.local"，且 K8s 里已应用 loki/httproute-loki-push.yaml。
# 软件源：Fluent Bit 官方 apt 仓库 packages.fluentbit.io/ubuntu/<代号>，GPG 签名校验。
set -euo pipefail
ROLE="${1:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOKI_HOST=loki.lab.local
KEYRING=/usr/share/keyrings/fluentbit-keyring.gpg
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
[[ "$ROLE" == "web" || "$ROLE" == "db" ]] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[[ $EUID -eq 0 ]] || die "请用 root 执行"
command -v apt-get >/dev/null || die "这个脚本只支持 Ubuntu（apt）"
# shellcheck disable=SC1091
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
[[ -n "$CODENAME" ]] || die "读不到 /etc/os-release 里的 VERSION_CODENAME"
# 1. 检查能不能解析和访问 Loki 的写入地址
if ! getent hosts "$LOKI_HOST" >/dev/null; then
  die "解析不了 ${LOKI_HOST}，先在 /etc/hosts 里加：192.168.56.200  ${LOKI_HOST}"
fi
code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST -H 'Content-Type: application/json' \
  -H 'X-Scope-OrgID: mall' --data '{"streams":[]}' "http://${LOKI_HOST}/loki/api/v1/push" || true)"
case "$code" in
  204 | 200 | 400 | 422) log "${LOKI_HOST} 可以访问（HTTP ${code}，空数据返回 4xx 属于正常）" ;;
  *) die "访问 http://${LOKI_HOST}/loki/api/v1/push 返回 ${code}，检查网关和 HTTPRoute" ;;
esac
# 2. 添加官方软件源（DEB822 格式）并安装
if ! dpkg -s fluent-bit >/dev/null 2>&1; then
  log "添加 Fluent Bit 软件源（packages.fluentbit.io/ubuntu/${CODENAME}）"
  apt-get install -y -q ca-certificates curl gpg >/dev/null
  curl -fsSL https://packages.fluentbit.io/fluentbit.key | gpg --dearmor --yes -o "$KEYRING"
  cat >/etc/apt/sources.list.d/fluent-bit.sources <<EOF
Types: deb
URIs: https://packages.fluentbit.io/ubuntu/${CODENAME}
Suites: ${CODENAME}
Components: main
Signed-By: ${KEYRING}
EOF
  apt-get update -q
  apt-get install -y -q fluent-bit
fi
log "已安装：$(/opt/fluent-bit/bin/fluent-bit --version | head -1)"
# 3. 写配置。原配置备份一份，方便对比
install -d -m 0750 /var/lib/fluent-bit/storage
[[ -f /etc/fluent-bit/fluent-bit.conf.orig ]] || cp /etc/fluent-bit/fluent-bit.conf /etc/fluent-bit/fluent-bit.conf.orig
install -m 0644 "$HERE/parsers-vm.conf" /etc/fluent-bit/parsers-vm.conf
sed "s/__HOSTNAME__/$(hostname -s)/g" "$HERE/fluent-bit-${ROLE}.conf" >/etc/fluent-bit/fluent-bit.conf
# 4. 先做语法检查，通过了再重启，避免把正在跑的服务弄挂
/opt/fluent-bit/bin/fluent-bit --dry-run -c /etc/fluent-bit/fluent-bit.conf >/dev/null 2>&1 \
  || die "配置检查没通过，执行 /opt/fluent-bit/bin/fluent-bit --dry-run -c /etc/fluent-bit/fluent-bit.conf 看报错"
systemctl enable --now fluent-bit
systemctl restart fluent-bit
sleep 3
systemctl is-active --quiet fluent-bit || die "fluent-bit 没起来，journalctl -u fluent-bit -n 50 看原因"
log "fluent-bit 运行中。看各输入输出的计数：curl -s 127.0.0.1:2020/api/v1/metrics"
