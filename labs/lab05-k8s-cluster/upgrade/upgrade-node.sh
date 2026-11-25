#!/usr/bin/env bash
# 升级一台工作节点：v1.35.x -> v1.36.x（控制平面必须已经升级完）
# 严格按 Kubernetes 官方 Upgrading Linux nodes 的顺序：
#   换源 -> 升级 kubeadm、kubectl -> kubeadm upgrade node -> （master 上）drain -> 升级 kubelet -> 重启 kubelet -> （master 上）uncordon
#
# 用法（在要升级的工作节点上 root 执行，一次只升一台）：
#   sudo ./upgrade-node.sh 1.36.6
# drain / uncordon 要在 k8s-master 上执行，脚本到那一步会停下来提示你
# 对应教程：Lab 05 K8s 集群搭建与日常维护
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-}"
NODE_NAME="${NODE_NAME:-$(hostname -s)}"
KUBE_REPO="${KUBE_REPO:-aliyun}"
IMAGE_REPO="${IMAGE_REPO:-registry.aliyuncs.com/google_containers}"

log() {
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2"
}

trap 'log ERROR "第 ${LINENO} 行执行失败：${BASH_COMMAND}"' ERR

wait_master() {
  log ACTION "请到 k8s-master 上执行：$1"
  read -r -p "执行完、看到预期输出后按回车继续 " _
}

pkg_install() {
  local p args=()
  if command -v dnf >/dev/null; then
    for p in "$@"; do args+=("${p}-${TARGET}"); done
    dnf install -y "${args[@]}" --disableexcludes=kubernetes
  else
    for p in "$@"; do args+=("${p}=${TARGET}-*"); done
    apt-mark unhold "$@"
    apt-get install -y "${args[@]}"
    apt-mark hold "$@"
  fi
}

main() {
  if (( EUID != 0 )); then
    echo "请用 root 执行" >&2
    exit 2
  fi
  if [[ ! "$TARGET" =~ ^1\.[0-9]+\.[0-9]+$ ]]; then
    echo "用法: $0 1.36.6" >&2
    exit 2
  fi
  local minor="v${TARGET%.*}"

  log STEP "1/5 软件源切到 ${minor}，升级 kubeadm、kubectl"
  KUBE_MINOR="$minor" KUBE_REPO="$KUBE_REPO" REPO_ONLY=true "${SCRIPT_DIR}/../install-kube.sh"
  pkg_install kubeadm kubectl

  log STEP "2/5 kubeadm upgrade node：从集群取新配置，更新本机 kubelet 配置"
  kubeadm upgrade node

  wait_master "kubectl drain ${NODE_NAME} --ignore-daemonsets --delete-emptydir-data"

  log STEP "3/5 升级 kubelet"
  pkg_install kubelet
  local want
  want="$(kubeadm config images list --kubernetes-version "v${TARGET}" --image-repository "$IMAGE_REPO" | grep '/pause:')"
  if ! grep -qF "sandbox = '${want}'" /etc/containerd/config.toml; then
    sed -ri "s#^(\s*)sandbox = .*#\1sandbox = '${want}'#" /etc/containerd/config.toml
    systemctl restart containerd
    log INFO "containerd sandbox 已改为 ${want}"
  fi

  log STEP "4/5 重启 kubelet"
  systemctl daemon-reload
  systemctl restart kubelet
  systemctl is-active kubelet

  log STEP "5/5 恢复调度"
  wait_master "kubectl uncordon ${NODE_NAME} && kubectl get nodes -o wide"
  log INFO "${NODE_NAME} 已升级到 v${TARGET}"
}

main "$@"
