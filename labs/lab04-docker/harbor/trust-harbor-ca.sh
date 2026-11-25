#!/usr/bin/env bash
# 让一台机器信任 Harbor 的自签 CA：系统、Docker、containerd 三处
#
# 用法（在要拉 / 推镜像的机器上 root 执行，先把 lab-dev 的 /data/cert/ca.crt 拷过来）：
#   scp ops@192.168.56.15:/data/cert/ca.crt /tmp/harbor-ca.crt
#   sudo ./trust-harbor-ca.sh /tmp/harbor-ca.crt
#
# 支持 Rocky Linux 9（update-ca-trust）和 Ubuntu 24.04（update-ca-certificates）

set -Eeuo pipefail

HARBOR_DOMAIN="${HARBOR_DOMAIN:-harbor.lab.local}"
CA_FILE="${1:-}"

log() {
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2"
}

main() {
  if [[ -z "$CA_FILE" || ! -r "$CA_FILE" ]]; then
    echo "用法: $0 <ca.crt 路径>" >&2
    exit 2
  fi
  if (( EUID != 0 )); then
    echo "请用 root 执行" >&2
    exit 2
  fi

  # 1. 系统信任：curl、浏览器（部分）、Go 程序都会用
  if command -v update-ca-trust >/dev/null; then
    cp "$CA_FILE" /etc/pki/ca-trust/source/anchors/ops-mall-lab-ca.crt
    update-ca-trust extract
    log INFO "已加入系统信任（RHEL 系）"
  elif command -v update-ca-certificates >/dev/null; then
    cp "$CA_FILE" /usr/local/share/ca-certificates/ops-mall-lab-ca.crt
    update-ca-certificates
    log INFO "已加入系统信任（Debian / Ubuntu 系）"
  fi

  # 2. Docker：/etc/docker/certs.d/<仓库域名>/ca.crt，不需要重启 dockerd
  if command -v docker >/dev/null; then
    mkdir -p "/etc/docker/certs.d/${HARBOR_DOMAIN}"
    cp "$CA_FILE" "/etc/docker/certs.d/${HARBOR_DOMAIN}/ca.crt"
    log INFO "已配置 Docker 信任 ${HARBOR_DOMAIN}"
  fi

  # 3. containerd（K8s 节点）：/etc/containerd/certs.d/<仓库域名>/hosts.toml
  #    前提：containerd 配置里 registry 的 config_path 指向 /etc/containerd/certs.d（见教程）
  if command -v containerd >/dev/null; then
    mkdir -p "/etc/containerd/certs.d/${HARBOR_DOMAIN}"
    cp "$CA_FILE" "/etc/containerd/certs.d/${HARBOR_DOMAIN}/ca.crt"
    cat > "/etc/containerd/certs.d/${HARBOR_DOMAIN}/hosts.toml" <<EOF
server = "https://${HARBOR_DOMAIN}"

[host."https://${HARBOR_DOMAIN}"]
  capabilities = ["pull", "resolve", "push"]
  ca = "/etc/containerd/certs.d/${HARBOR_DOMAIN}/ca.crt"
EOF
    log INFO "已配置 containerd 信任 ${HARBOR_DOMAIN}（hosts.toml 修改即时生效）"
  fi
}

main "$@"
