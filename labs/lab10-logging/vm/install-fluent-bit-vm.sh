#!/usr/bin/env bash
# Lab 10：在虚拟机上安装 Fluent Bit，把日志推到 K8s 里的 Loki
#
# 用法（root 执行，在本目录下）：
#   ./install-fluent-bit-vm.sh web    # lab-web1、lab-web2：Nginx 访问 / 错误日志 + mall-api 的 journald 日志
#   ./install-fluent-bit-vm.sh db     # lab-db1：MySQL 慢日志 + 错误日志
#
# 前提：hosts 里有 "192.168.56.200 loki.lab.local"，且 K8s 里已应用 loki/httproute-loki-push.yaml。
# 软件源：Fluent Bit 官方仓库 packages.fluentbit.io，Rocky Linux 用 rockylinux 路径。
# Ubuntu 24.04 的装法见教程，脚本只处理 Rocky / RHEL 系。
set -euo pipefail

ROLE="${1:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

[[ "$ROLE" == "web" || "$ROLE" == "db" ]] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[[ $EUID -eq 0 ]] || die "请用 root 执行"
command -v dnf >/dev/null || die "这个脚本只支持 Rocky Linux / RHEL 系（dnf）"

# 1. 检查能不能解析和访问 Loki 的写入地址
if ! getent hosts loki.lab.local >/dev/null; then
  die "解析不了 loki.lab.local，先在 /etc/hosts 里加：192.168.56.200  loki.lab.local"
fi
code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST -H 'Content-Type: application/json' \
  -H 'X-Scope-OrgID: mall' --data '{"streams":[]}' http://loki.lab.local/loki/api/v1/push || true)"
case "$code" in
  204 | 200 | 400 | 422) log "loki.lab.local 可以访问（HTTP ${code}，空数据返回 4xx 属于正常）" ;;
  *) die "访问 http://loki.lab.local/loki/api/v1/push 返回 ${code}，检查网关和 HTTPRoute" ;;
esac

# 2. 添加官方软件源并安装
if ! rpm -q fluent-bit >/dev/null 2>&1; then
  log "添加 Fluent Bit 软件源"
  cat >/etc/yum.repos.d/fluent-bit.repo <<'EOF'
[fluent-bit]
name=Fluent Bit
baseurl=https://packages.fluentbit.io/rockylinux/$releasever/
gpgcheck=1
gpgkey=https://packages.fluentbit.io/fluentbit.key
repo_gpgcheck=1
enabled=1
EOF
  dnf install -y fluent-bit
fi
log "已安装：$(/opt/fluent-bit/bin/fluent-bit --version | head -1)"

# 3. 写配置。原配置备份一份，方便对比
install -d -m 0750 /var/lib/fluent-bit/storage
[[ -f /etc/fluent-bit/fluent-bit.conf.orig ]] || cp /etc/fluent-bit/fluent-bit.conf /etc/fluent-bit/fluent-bit.conf.orig
install -m 0644 "$HERE/parsers-vm.conf" /etc/fluent-bit/parsers-vm.conf
sed "s/__HOSTNAME__/$(hostname -s)/g" "$HERE/fluent-bit-${ROLE}.conf" >/etc/fluent-bit/fluent-bit.conf

# 4. 先做语法检查，通过了再重启，避免把正在跑的服务弄挂
/opt/fluent-bit/bin/fluent-bit --dry-run -c /etc/fluent-bit/fluent-bit.conf >/dev/null \
  || die "配置检查没通过，执行 /opt/fluent-bit/bin/fluent-bit --dry-run -c /etc/fluent-bit/fluent-bit.conf 看报错"

systemctl enable --now fluent-bit
systemctl restart fluent-bit
sleep 3
systemctl is-active --quiet fluent-bit || die "fluent-bit 没起来，journalctl -u fluent-bit -n 50 看原因"
log "fluent-bit 运行中。看各输入输出的计数：curl -s 127.0.0.1:2020/api/v1/metrics"
