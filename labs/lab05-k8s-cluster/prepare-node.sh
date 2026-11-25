#!/usr/bin/env bash
# K8s 节点初始化（Ubuntu Server 24.04 LTS）：主机名、hosts、swap、内核模块、sysctl、chrony、AppArmor 检查、ufw、kubelet 节点 IP
#
# 用法（每台 K8s 节点 root 执行，主机名和 IP 按本机填）：
#   sudo NODE_NAME=k8s-master NODE_IP=192.168.56.21 ./prepare-node.sh
#   sudo NODE_NAME=k8s-node1  NODE_IP=192.168.56.22 ./prepare-node.sh
#   sudo NODE_NAME=k8s-node2  NODE_IP=192.168.56.23 ./prepare-node.sh
#
# 防火墙两种取舍（FIREWALL_MODE）：
#   disable（默认）  实验环境关闭 ufw，少踩坑
#   open            启用 ufw，按节点角色放行 K8s、Calico、MetalLB 端口（生产思路）
#
# 对应教程：Lab 05 K8s 集群搭建与日常维护
set -Eeuo pipefail

NODE_NAME="${NODE_NAME:-}"
NODE_IP="${NODE_IP:-}"
NODE_ROLE="${NODE_ROLE:-}"                 # master / worker，不填按主机名判断
FIREWALL_MODE="${FIREWALL_MODE:-disable}"
LAB_NET="${LAB_NET:-192.168.56}"           # 实验网段前三段，VMware / 云服务器按实际替换
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"      # 和 kubeadm-config.yaml 的 podSubnet 一致
SVC_CIDR="${SVC_CIDR:-10.96.0.0/12}"

log() {
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2"
}
trap 'log ERROR "第 ${LINENO} 行执行失败：${BASH_COMMAND}"' ERR

check_args() {
  if (( EUID != 0 )); then
    echo "请用 root 执行" >&2
    exit 2
  fi
  if [[ -z "$NODE_NAME" || -z "$NODE_IP" ]]; then
    echo "用法: NODE_NAME=k8s-master NODE_IP=${LAB_NET}.21 $0" >&2
    exit 2
  fi
  if [[ "$FIREWALL_MODE" != disable && "$FIREWALL_MODE" != open ]]; then
    echo "FIREWALL_MODE 只能是 disable 或 open" >&2
    exit 2
  fi
  if [[ -z "$NODE_ROLE" ]]; then
    if [[ "$NODE_NAME" == *master* ]]; then NODE_ROLE=master; else NODE_ROLE=worker; fi
  fi
  if ! ip -4 addr | grep -q "inet ${NODE_IP}/"; then
    echo "本机网卡上没有 ${NODE_IP}，检查 NODE_IP 是否写错" >&2
    exit 2
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != ubuntu || "${VERSION_ID:-}" != 24.04 ]]; then
    log WARN "本脚本按 Ubuntu 24.04 编写，当前是 ${PRETTY_NAME:-未知系统}，继续执行但请留意报错"
  fi
}

set_hostname_and_hosts() {
  if [[ "$(hostname)" != "$NODE_NAME" ]]; then
    hostnamectl set-hostname "$NODE_NAME"
  fi
  # 先删掉旧的实验条目再写，脚本可以重复执行
  # 用 cat > 原地覆盖而不是 sed -i：sed -i 会换掉文件 inode，/etc/hosts 是挂载点（容器、WSL）时会失败
  local kept
  kept="$(grep -v '# ops-mall-lab05$' /etc/hosts || true)"
  printf '%s\n' "$kept" > /etc/hosts
  cat >> /etc/hosts <<EOF
${LAB_NET}.21 k8s-master k8s-api.lab.local # ops-mall-lab05
${LAB_NET}.22 k8s-node1 # ops-mall-lab05
${LAB_NET}.23 k8s-node2 # ops-mall-lab05
${LAB_NET}.15 harbor.lab.local # ops-mall-lab05
EOF
  log INFO "主机名 ${NODE_NAME}，hosts 已写入（k8s-api.lab.local 指向 master）"
}

disable_swap() {
  # kubelet 默认 failSwapOn: true，检测到 swap 就拒绝启动
  swapoff -a
  # Ubuntu 24.04 安装器默认建 /swap.img，fstab 里是 "/swap.img none swap sw 0 0"，注释掉
  sed -ri '/^[^#].*\sswap\s/s/^/#/' /etc/fstab
  # 桌面版或手工装过 zram-tools / systemd-zram-generator 的机器可能有 zram swap
  if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-zram-setup@'; then
    systemctl mask --now systemd-zram-setup@zram0.service || true
  fi
  if [[ -n "$(swapon --show --noheadings)" ]]; then
    log ERROR "swap 仍未关闭，请手工检查 swapon --show"
    exit 1
  fi
  log INFO "swap 已关闭并注释 /etc/fstab"
}

load_modules() {
  cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter
  log INFO "已加载 overlay、br_netfilter，开机由 systemd-modules-load 自动加载"
}

set_sysctl() {
  cat > /etc/sysctl.d/99-k8s.conf <<EOF
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
  # 只加载这一个文件；sysctl --system 会把 /etc/sysctl.d 下所有文件都重新应用一遍
  sysctl -q -p /etc/sysctl.d/99-k8s.conf
  log INFO "ip_forward=$(sysctl -n net.ipv4.ip_forward) bridge-nf-call-iptables=$(sysctl -n net.bridge.bridge-nf-call-iptables)"
}

install_base_and_time() {
  apt-get update -qq
  # gpg：install-kube.sh 导入 pkgs.k8s.io 密钥要用；conntrack / socat：kubeadm 预检要求
  # Ubuntu 24.04 装 chrony 会自动替换掉自带的 systemd-timesyncd
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    ca-certificates curl gpg chrony conntrack socat ipvsadm apparmor >/dev/null
  systemctl enable --now chrony >/dev/null 2>&1
  timedatectl set-timezone Asia/Shanghai
  # 证书和 etcd 都依赖时间一致，时间差太多会出现 x509 证书尚未生效
  chronyc makestep >/dev/null || true
  log INFO "chrony 已启动，时区 Asia/Shanghai"
}

check_apparmor() {
  # Ubuntu 默认开启 AppArmor，K8s 不要求关闭：containerd 会给容器套默认的 cri-containerd.apparmor.d 配置
  # （RHEL 系对应的是 SELinux，kubeadm 文档要求设为 permissive；Ubuntu 上没有这一步）
  if aa-enabled -q 2>/dev/null; then
    log INFO "AppArmor 已启用，保持开启（$(aa-status --profiled 2>/dev/null || echo '?') 个配置已加载）"
  else
    log WARN "AppArmor 未启用（容器环境或内核参数关闭了它），不影响实验"
  fi
}

set_firewall() {
  if ! command -v ufw >/dev/null; then
    log WARN "没装 ufw，跳过防火墙配置"
    return 0
  fi
  if [[ "$FIREWALL_MODE" == disable ]]; then
    ufw disable >/dev/null || true
    log INFO "ufw 已关闭（实验取舍，生产用 FIREWALL_MODE=open 或云安全组）"
    return 0
  fi
  local ports=(22/tcp 10250/tcp 10256/tcp)
  if [[ "$NODE_ROLE" == master ]]; then
    ports+=(6443/tcp 2379:2380/tcp 10257/tcp 10259/tcp)
  else
    ports+=(30000:32767/tcp 30000:32767/udp)
  fi
  # Calico：BGP 179、VXLAN 4789、Typha 5473；MetalLB L2 成员发现 7946（Lab 06）
  ports+=(179/tcp 4789/udp 5473/tcp 7946/tcp 7946/udp)
  local p
  for p in "${ports[@]}"; do
    ufw allow "$p" >/dev/null
  done
  # Pod、Service 网段的流量放行，否则跨节点 Pod 不通
  ufw allow from "$POD_CIDR" >/dev/null
  ufw allow from "$SVC_CIDR" >/dev/null
  # ufw 默认 FORWARD 策略是 DROP，Pod 流量要经过节点转发，必须放开
  ufw default allow routed >/dev/null
  ufw --force enable >/dev/null
  log INFO "ufw 已启用并放行 ${NODE_ROLE} 端口：${ports[*]}，以及 ${POD_CIDR}、${SVC_CIDR}"
}

set_kubelet_node_ip() {
  # VirtualBox 每台机器都有一块 NAT 网卡（10.0.2.15），不指定的话 kubelet 会把它当节点 IP
  # deb 包里 kubelet 的 systemd drop-in 会读 /etc/default/kubelet 的 KUBELET_EXTRA_ARGS
  echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" > /etc/default/kubelet
  log INFO "已写入 /etc/default/kubelet：--node-ip=${NODE_IP}"
}

main() {
  check_args
  set_hostname_and_hosts
  disable_swap
  load_modules
  set_sysctl
  install_base_and_time
  check_apparmor
  set_firewall
  set_kubelet_node_ip
  log INFO "节点 ${NODE_NAME}（${NODE_ROLE}）准备完成，下一步 install-containerd.sh"
}

main "$@"
