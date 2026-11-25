#!/usr/bin/env bash
# 安装 containerd 2.x（Ubuntu 24.04）并按 K8s 要求配置
#   1. SystemdCgroup = true（和 kubelet 的 systemd cgroup 驱动一致）
#   2. sandbox（pause）镜像换成国内地址
#   3. registry config_path = /etc/containerd/certs.d，用 hosts.toml 配 Harbor 自签证书
#
# 用法（每台 K8s 节点 root 执行；先把 lab-dev 的 /data/cert/ca.crt 拷到本机）：
#   scp ops@192.168.56.15:/data/cert/ca.crt /tmp/harbor-ca.crt
#   sudo HARBOR_CA=/tmp/harbor-ca.crt ./install-containerd.sh
#   sudo CONTAINERD_VERSION=2.4.2 ./install-containerd.sh      # 指定版本
#
# 安装来源：Docker 官方 apt 源里的 containerd.io 包（只装 containerd，不装 dockerd）
# 写作时 noble（24.04）源里最新的是 containerd.io 2.4.2-4，以 download.docker.com 实际内容为准
# 对应教程：Lab 05 K8s 集群搭建与日常维护
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-}"     # 空表示装源里最新的；指定如 2.4.2
# 国内默认用阿里云的 Docker CE 镜像；能直连就改成 https://download.docker.com
DOCKER_CE_MIRROR="${DOCKER_CE_MIRROR:-https://mirrors.aliyun.com/docker-ce}"
# kubeadm v1.36 / v1.37 默认都是 pause:3.10.2；install-kube.sh 装完 kubeadm 后会按实际版本再校正一次
SANDBOX_IMAGE="${SANDBOX_IMAGE:-registry.aliyuncs.com/google_containers/pause:3.10.2}"
HARBOR_DOMAIN="${HARBOR_DOMAIN:-harbor.lab.local}"
HARBOR_CA="${HARBOR_CA:-}"

CONFIG=/etc/containerd/config.toml
CERTS_DIR=/etc/containerd/certs.d

log() {
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2"
}
trap 'log ERROR "第 ${LINENO} 行执行失败：${BASH_COMMAND}"' ERR

install_pkg() {
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "${DOCKER_CE_MIRROR}/linux/ubuntu/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  # DEB822 格式（Docker 官方文档现在的写法）；老文档里的 docker.list 单行写法删掉，避免重复源
  rm -f /etc/apt/sources.list.d/docker.list
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: ${DOCKER_CE_MIRROR}/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update -qq
  if [[ -n "$CONTAINERD_VERSION" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "containerd.io=${CONTAINERD_VERSION}-*" >/dev/null
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq containerd.io >/dev/null
  fi
  local ver
  ver="$(containerd --version | awk '{print $3}')"
  if [[ "$ver" != v2.* && "$ver" != 2.* ]]; then
    log ERROR "装上的 containerd 是 ${ver}，本实验要求 2.x"
    exit 1
  fi
  log INFO "containerd ${ver} 已安装（containerd.io $(dpkg-query -W -f='${Version}' containerd.io)）"
}

write_config() {
  mkdir -p /etc/containerd
  # containerd.io 包自带的 config.toml 里 disabled_plugins = ["cri"]，K8s 用不了，直接重新生成
  if [[ -f "$CONFIG" ]]; then
    cp -a "$CONFIG" "${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  containerd config default > "$CONFIG"
  # containerd 2.0-2.2 生成 version = 3，2.3 起生成 version = 4；两者 CRI 插件的键名一样
  if ! grep -qE '^version = [34]$' "$CONFIG"; then
    log ERROR "生成的配置不是 version = 3 / 4，确认 containerd 是 2.x"
    exit 1
  fi
  # 2.x 的键在 [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  sed -ri 's/^(\s*)SystemdCgroup = .*/\1SystemdCgroup = true/' "$CONFIG"
  # 2.x 的 pause 镜像在 [plugins.'io.containerd.cri.v1.images'.pinned_images] 的 sandbox 键
  sed -ri "s#^(\s*)sandbox = .*#\1sandbox = '${SANDBOX_IMAGE}'#" "$CONFIG"
  # 2.x 的 registry 目录在 [plugins.'io.containerd.cri.v1.images'.registry] 的 config_path 键
  sed -ri "s#^(\s*)config_path = .*#\1config_path = '${CERTS_DIR}'#" "$CONFIG"

  local k
  for k in "SystemdCgroup = true" "sandbox = '${SANDBOX_IMAGE}'" "config_path = '${CERTS_DIR}'"; do
    if ! grep -qF "$k" "$CONFIG"; then
      log ERROR "config.toml 里没改成功：${k}。containerd 默认配置格式可能变了，对照教程手工改"
      exit 1
    fi
  done
  log INFO "config.toml 已生成：SystemdCgroup=true、sandbox=${SANDBOX_IMAGE}、config_path=${CERTS_DIR}"
}

write_registry_hosts() {
  mkdir -p "${CERTS_DIR}/${HARBOR_DOMAIN}"
  if [[ -n "$HARBOR_CA" ]]; then
    if [[ ! -r "$HARBOR_CA" ]]; then
      log ERROR "读不到 HARBOR_CA=${HARBOR_CA}"
      exit 2
    fi
    cp "$HARBOR_CA" "${CERTS_DIR}/${HARBOR_DOMAIN}/ca.crt"
  else
    log WARN "没给 HARBOR_CA，先跳过 Harbor 证书；之后把 ca.crt 放到 ${CERTS_DIR}/${HARBOR_DOMAIN}/ 即可"
  fi
  # hosts.toml 修改后不用重启 containerd，每次拉镜像都会重新读取
  sed "s#harbor.lab.local#${HARBOR_DOMAIN}#g" \
    "${SCRIPT_DIR}/containerd/certs.d/harbor.lab.local/hosts.toml" \
    > "${CERTS_DIR}/${HARBOR_DOMAIN}/hosts.toml"
  log INFO "已写入 ${CERTS_DIR}/${HARBOR_DOMAIN}/hosts.toml"
}

write_crictl_config() {
  # crictl 来自 cri-tools 包（install-kube.sh 里单独装，新版 kubeadm 包不再依赖它）
  cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF
}

main() {
  if (( EUID != 0 )); then
    echo "请用 root 执行" >&2
    exit 2
  fi
  install_pkg
  write_config
  write_registry_hosts
  write_crictl_config
  systemctl enable containerd >/dev/null 2>&1
  systemctl restart containerd
  sleep 2
  systemctl is-active --quiet containerd
  # dump 出来的是合并后的最终配置，确认 CRI 插件读到了我们的值
  containerd config dump | grep -E "SystemdCgroup|sandbox = |config_path" || true
  log INFO "containerd 已启动，下一步 install-kube.sh"
}

main "$@"
