#!/usr/bin/env bash
# 安装 kubeadm / kubelet / kubectl（Ubuntu 24.04，pkgs.k8s.io 社区源或阿里云镜像），并 apt-mark hold 锁定版本
#
# 用法（每台 K8s 节点 root 执行）：
#   sudo ./install-kube.sh                                  # 默认 v1.36 最新补丁版，阿里云镜像
#   sudo KUBE_MINOR=v1.36 KUBE_PATCH=1.36.6 ./install-kube.sh
#   sudo KUBE_REPO=official ./install-kube.sh               # 能直连 pkgs.k8s.io 时
#   sudo KUBE_MINOR=v1.37 REPO_ONLY=true ./install-kube.sh  # 升级前只切换软件源，不装包
#
# pkgs.k8s.io 每个小版本一个独立的源，升级小版本必须先换源（官方升级文档的要求）
# 写作时：v1.36 最新 1.36.6，v1.37 最新 1.37.2，以软件源实际内容为准
# 对应教程：Lab 05 K8s 集群搭建与日常维护
set -Eeuo pipefail

KUBE_MINOR="${KUBE_MINOR:-v1.36}"
KUBE_PATCH="${KUBE_PATCH:-}"                     # 如 1.36.6；空表示源里最新
KUBE_REPO="${KUBE_REPO:-aliyun}"                 # aliyun / official
REPO_ONLY="${REPO_ONLY:-false}"
IMAGE_REPO="${IMAGE_REPO:-registry.aliyuncs.com/google_containers}"

KEYRING=/etc/apt/keyrings/kubernetes-apt-keyring.gpg
SOURCES=/etc/apt/sources.list.d/kubernetes.sources
CONTAINERD_CONFIG=/etc/containerd/config.toml

log() {
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2"
}
trap 'log ERROR "第 ${LINENO} 行执行失败：${BASH_COMMAND}"' ERR

repo_base() {
  case "$KUBE_REPO" in
    official) echo "https://pkgs.k8s.io/core:/stable:/${KUBE_MINOR}/deb/" ;;
    aliyun)   echo "https://mirrors.aliyun.com/kubernetes-new/core/stable/${KUBE_MINOR}/deb/" ;;
    *) echo "KUBE_REPO 只能是 aliyun 或 official" >&2; exit 2 ;;
  esac
}

write_repo() {
  local base
  base="$(repo_base)"
  install -m 0755 -d /etc/apt/keyrings
  # 所有小版本用同一把签名密钥，换源时重新导入也没关系
  curl -fsSL "${base}Release.key" | gpg --dearmor --yes -o "$KEYRING"
  chmod a+r "$KEYRING"
  # 官方文档写的是单行 kubernetes.list；这里用 Ubuntu 24.04 推荐的 DEB822 格式，二者只留一个
  rm -f /etc/apt/sources.list.d/kubernetes.list
  # 这个源是“扁平仓库”：Suites 写 /，不写 Components
  cat > "$SOURCES" <<EOF
Types: deb
URIs: ${base}
Suites: /
Signed-By: ${KEYRING}
EOF
  apt-get update -qq
  log INFO "Kubernetes 软件源已切到 ${KUBE_MINOR}（${KUBE_REPO}），可装版本：$(apt-cache madison kubeadm | awk '{print $3}' | sort -V | tail -1)"
}

install_pkgs() {
  # 先解锁再装，装完重新锁定；hold 之后 apt upgrade 不会顺手升级这三个包
  apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
  local pkgs=(kubelet kubeadm kubectl)
  if [[ -n "$KUBE_PATCH" ]]; then
    pkgs=("kubelet=${KUBE_PATCH}-*" "kubeadm=${KUBE_PATCH}-*" "kubectl=${KUBE_PATCH}-*")
  fi
  # 新版 kubeadm 包不再依赖 cri-tools，crictl 要单独装（节点上排查容器全靠它）
  pkgs+=(cri-tools)
  # /etc/default/kubelet 是 kubelet 包的配置文件，prepare-node.sh 已经写过 --node-ip，
  # 不加 --force-confold 的话 dpkg 会停下来问“要不要用包里的版本覆盖”
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o Dpkg::Options::=--force-confold "${pkgs[@]}" >/dev/null
  apt-mark hold kubelet kubeadm kubectl
  # 先 enable，kubeadm init / join 写好配置后 kubelet 才能真正跑起来，之前反复重启是正常的
  systemctl enable --now kubelet >/dev/null 2>&1
  log INFO "已安装 kubeadm $(kubeadm version -o short)，kubelet $(kubelet --version | awk '{print $2}')，kubectl $(kubectl version --client | awk '/Client Version/{print $3}')，crictl $(crictl --version | awk '{print $3}')"
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
    echo "KUBE_MINOR 格式应为 v1.36" >&2
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
