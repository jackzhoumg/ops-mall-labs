#!/usr/bin/env bash
# 在 k8s-master 上安装和集群 etcd 同版本的 etcdctl / etcdutl（只装客户端工具，不装 etcd 服务）
#
# 用法：
#   sudo ./install-etcd-tools.sh                    # 自动从 etcd 静态 Pod 清单里读版本
#   sudo ETCD_VERSION=v3.6.6 ./install-etcd-tools.sh
#   sudo ETCD_MIRROR=https://github.com/etcd-io/etcd/releases/download ./install-etcd-tools.sh
#
# 写作时 kubeadm v1.35 默认 etcd 3.6.6，v1.36 默认 3.6.8
# 对应教程：Lab 05 K8s 集群搭建与日常维护
set -Eeuo pipefail

ETCD_VERSION="${ETCD_VERSION:-}"
# 国内默认华为云镜像，目录结构 <mirror>/<版本>/etcd-<版本>-linux-<架构>.tar.gz，和 GitHub Releases 一致
ETCD_MIRROR="${ETCD_MIRROR:-https://mirrors.huaweicloud.com/etcd}"
MANIFEST=/etc/kubernetes/manifests/etcd.yaml

log() {
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2"
}

main() {
  if (( EUID != 0 )); then
    echo "请用 root 执行" >&2
    exit 2
  fi
  if [[ -z "$ETCD_VERSION" ]]; then
    # 镜像标签形如 etcd:3.6.6-0，取 -0 前面的部分
    ETCD_VERSION="v$(grep -oE 'etcd:[0-9.]+' "$MANIFEST" | head -1 | cut -d: -f2)"
  fi
  local arch
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) echo "不支持的架构 $(uname -m)" >&2; exit 2 ;;
  esac
  local pkg="etcd-${ETCD_VERSION}-linux-${arch}"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  log INFO "下载 ${ETCD_MIRROR}/${ETCD_VERSION}/${pkg}.tar.gz"
  curl -fsSL "${ETCD_MIRROR}/${ETCD_VERSION}/${pkg}.tar.gz" -o "${tmp}/etcd.tgz"
  tar -xzf "${tmp}/etcd.tgz" -C "$tmp"
  install -m 0755 "${tmp}/${pkg}/etcdctl" "${tmp}/${pkg}/etcdutl" /usr/local/bin/
  log INFO "已安装 $(etcdctl version | head -1)，$(etcdutl version | head -1)"
}

main "$@"
