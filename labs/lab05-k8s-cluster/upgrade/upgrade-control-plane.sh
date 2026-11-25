#!/usr/bin/env bash
# 升级第一台（本实验唯一一台）控制平面：v1.36.x -> v1.37.x
# 严格按 Kubernetes 官方 Upgrading kubeadm clusters 的顺序：
#   换源 -> 升级 kubeadm -> upgrade plan -> upgrade apply -> drain -> 升级 kubelet/kubectl -> 重启 kubelet -> uncordon
#
# 用法（k8s-master 上 root 执行，升级前先跑 etcd/etcd-backup.sh）：
#   sudo ./upgrade-control-plane.sh 1.37.2
# 每一步执行前会停下来等你按回车，看清楚输出再继续；ASSUME_YES=true 可跳过等待
# 写作时 v1.37 最新补丁 1.37.2，以 apt-cache madison kubeadm 为准
# 对应教程：Lab 05 K8s 集群搭建与日常维护
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-}"                          # 如 1.37.2
NODE_NAME="${NODE_NAME:-$(hostname -s)}"
KUBE_REPO="${KUBE_REPO:-aliyun}"
ASSUME_YES="${ASSUME_YES:-false}"
# 和 kubeadm-config.yaml 的 imageRepository 一致
IMAGE_REPO="${IMAGE_REPO:-registry.aliyuncs.com/google_containers}"
export KUBECONFIG=/etc/kubernetes/admin.conf

log() {
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2"
}

trap 'log ERROR "第 ${LINENO} 行执行失败：${BASH_COMMAND}"' ERR

pause() {
  log STEP "$1"
  if [[ "$ASSUME_YES" != true ]]; then
    read -r -p "按回车继续，Ctrl+C 退出 " _
  fi
}

pkg_install() {
  # pkg_install kubeadm kubelet ...，版本统一用 TARGET
  local p args=()
  for p in "$@"; do args+=("${p}=${TARGET}-*"); done
  # 被 hold 的包要先解锁才能升级，升级完马上重新锁定
  apt-mark unhold "$@"
  # --force-confold：保留 /etc/default/kubelet 里的 --node-ip，不让 dpkg 停下来问
  DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confold "${args[@]}"
  apt-mark hold "$@"
}

main() {
  if (( EUID != 0 )); then
    echo "请用 root 执行" >&2
    exit 2
  fi
  if [[ ! "$TARGET" =~ ^1\.[0-9]+\.[0-9]+$ ]]; then
    echo "用法: $0 1.37.2" >&2
    exit 2
  fi
  local minor="v${TARGET%.*}"

  pause "0/7 当前状态（确认所有节点 Ready、etcd 已备份）"
  kubectl get nodes -o wide
  if ! find /var/backups/etcd -name 'etcd-*.db' -mmin -60 2>/dev/null | grep -q .; then
    log WARN "最近 1 小时没有 etcd 快照，先执行 etcd/etcd-backup.sh"
  fi

  pause "1/7 软件源切到 ${minor}"
  KUBE_MINOR="$minor" KUBE_REPO="$KUBE_REPO" REPO_ONLY=true "${SCRIPT_DIR}/../install-kube.sh"

  pause "2/7 只升级 kubeadm 到 ${TARGET}"
  pkg_install kubeadm
  kubeadm version -o short

  pause "3/7 kubeadm upgrade plan：检查能否升级、会升到哪些版本"
  kubeadm upgrade plan

  pause "4/7 kubeadm upgrade apply v${TARGET}：升级控制平面组件、etcd（v1.37 默认 3.7.0）、CoreDNS、kube-proxy，并续期证书"
  # 先提前拉镜像，减少 apply 过程中控制平面不可用的时间
  kubeadm config images pull --kubernetes-version "v${TARGET}" --image-repository "$IMAGE_REPO"
  kubeadm upgrade apply "v${TARGET}" --yes

  pause "5/7 drain ${NODE_NAME}：腾空节点再升级 kubelet"
  kubectl drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data

  pause "6/7 升级 kubelet、kubectl 并重启 kubelet"
  pkg_install kubelet kubectl
  # 新版本 kubeadm 期望的 pause 镜像可能变了，顺手校正 containerd（容器不会因重启 containerd 而退出）
  local want
  want="$(kubeadm config images list --kubernetes-version "v${TARGET}" --image-repository "$IMAGE_REPO" | grep '/pause:')"
  if ! grep -qF "sandbox = '${want}'" /etc/containerd/config.toml; then
    sed -ri "s#^(\s*)sandbox = .*#\1sandbox = '${want}'#" /etc/containerd/config.toml
    systemctl restart containerd
    log INFO "containerd sandbox 已改为 ${want}"
  fi
  systemctl daemon-reload
  systemctl restart kubelet

  pause "7/7 uncordon ${NODE_NAME}"
  kubectl uncordon "$NODE_NAME"
  kubectl get nodes -o wide
  log INFO "控制平面升级完成。接着逐台在工作节点上执行 upgrade-node.sh ${TARGET}"
}

main "$@"
