#!/usr/bin/env bash
# 安装 kubeadm / kubelet / kubectl（pkgs.k8s.io 社区源或阿里云镜像），并锁定版本
#
# 用法（每台 K8s 节点 root 执行）：
#   sudo ./install-kube.sh                                  # 默认 v1.35 最新补丁版，阿里云镜像
#   sudo KUBE_MINOR=v1.35 KUBE_PATCH=1.35.10 ./install-kube.sh
#   sudo KUBE_REPO=official ./install-kube.sh               # 能直连 pkgs.k8s.io 时
#   sudo KUBE_MINOR=v1.36 REPO_ONLY=true ./install-kube.sh  # 升级前只切换软件源，不装包
#
# pkgs.k8s.io 每个小版本一个独立的源，升级小版本必须先换源（官方升级文档的要求）
# 写作时：v1.35 最新 1.35.10，v1.36 最新 1.36.6，以软件源实际内容为准
# 对应教程：Lab 05 K8s 集群搭建与日常维护
set -Eeuo pipefail

KUBE_MINOR="${KUBE_MINOR:-v1.35}"
KUBE_PATCH="${KUBE_PATCH:-}"                     # 如 1.35.10；空表示源里最新
KUBE_REPO="${KUBE_REPO:-aliyun}"                 # aliyun / official
REPO_ONLY="${REPO_ONLY:-false}"
IMAGE_REPO="${IMAGE_REPO:-registry.aliyuncs.com/google_containers}"
CONTAINERD_CONFIG=/etc/containerd/config.toml

log() {
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2"
}

trap 'log ERROR "第 ${LINENO} 行执行失败：${BASH_COMMAND}"' ERR

repo_base() {
  case "$KUBE_REPO" in
    official) echo "https://pkgs.k8s.io/core:/stable:/${KUBE_MINOR}" ;;
    aliyun)   echo "https://mirrors.aliyun.com/kubernetes-new/core/stable/${KUBE_MINOR}" ;;
    *) echo "KUBE_REPO 只能是 aliyun 或 official" >&2; exit 2 ;;
  esac
}

write_repo() {
  local base
  base="$(repo_base)"
  if command -v dnf >/dev/null; then
    # exclude 让日常 dnf update 不会顺手把 K8s 组件升级掉（版本锁定）
    cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes ${KUBE_MINOR}
baseurl=${base}/rpm/
enabled=1
gpgcheck=1
gpgkey=${base}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
    dnf makecache -q --disablerepo='*' --enablerepo=kubernetes
  else
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "${base}/deb/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${base}/deb/ /" \
      > /etc/apt/sources.list.d/kubernetes.list
    apt-get update -qq
  fi
  log INFO "Kubernetes 软件源已切到 ${KUBE_MINOR}（${KUBE_REPO}）"
}

install_pkgs() {
  if command -v dnf >/dev/null; then
    if [[ -n "$KUBE_PATCH" ]]; then
      dnf install -y "kubelet-${KUBE_PATCH}" "kubeadm-${KUBE_PATCH}" "kubectl-${KUBE_PATCH}" --disableexcludes=kubernetes
    else
      dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
    fi
  else
    apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
    if [[ -n "$KUBE_PATCH" ]]; then
      apt-get install -y "kubelet=${KUBE_PATCH}-*" "kubeadm=${KUBE_PATCH}-*" "kubectl=${KUBE_PATCH}-*"
    else
      apt-get install -y kubelet kubeadm kubectl
    fi
    apt-mark hold kubelet kubeadm kubectl
  fi
  # 先 enable，kubeadm init / join 写好配置后 kubelet 才能真正跑起来，之前反复重启是正常的
  systemctl enable --now kubelet
  log INFO "已安装 $(kubeadm version -o short)，kubelet $(kubelet --version | awk '{print $2}')"
}

sync_sandbox_image() {
  # 让 containerd 的 pause 镜像和这个版本 kubeadm 期望的一致，避免 kubeadm init 预检告警
  [[ -f "$CONTAINERD_CONFIG" ]] || return 0
  local want
  want="$(kubeadm config images list --kubernetes-version "$(kubeadm version -o short)" \
          --image-repository "$IMAGE_REPO" 2>/dev/null | grep '/pause:' || true)"
  if [[ -z "$want" ]]; then
    log WARN "没取到 pause 镜像版本，跳过校正"
    return 0
  fi
  if grep -qF "sandbox = '${want}'" "$CONTAINERD_CONFIG"; then
    log INFO "containerd sandbox 已是 ${want}"
    return 0
  fi
  sed -ri "s#^(\s*)sandbox = .*#\1sandbox = '${want}'#" "$CONTAINERD_CONFIG"
  systemctl restart containerd
  log INFO "containerd sandbox 已校正为 ${want} 并重启 containerd"
}

main() {
  if (( EUID != 0 )); then
    echo "请用 root 执行" >&2
    exit 2
  fi
  if [[ ! "$KUBE_MINOR" =~ ^v1\.[0-9]+$ ]]; then
    echo "KUBE_MINOR 格式应为 v1.35" >&2
    exit 2
  fi
  write_repo
  if [[ "$REPO_ONLY" == true ]]; then
    return 0
  fi
  install_pkgs
  sync_sandbox_image
  log INFO "完成。master 上下一步：kubeadm init --config kubeadm-config.yaml"
}

main "$@"
