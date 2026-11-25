#!/usr/bin/env bash
# K8s 节点初始化：主机名、hosts、swap、内核模块、sysctl、chrony、SELinux、防火墙、kubelet 节点 IP
#
# 用法（每台 K8s 节点 root 执行，主机名和 IP 按本机填）：
#   sudo NODE_NAME=k8s-master NODE_IP=192.168.56.21 ./prepare-node.sh
#   sudo NODE_NAME=k8s-node1  NODE_IP=192.168.56.22 ./prepare-node.sh
#   sudo NODE_NAME=k8s-node2  NODE_IP=192.168.56.23 ./prepare-node.sh
#
# 防火墙两种取舍（FIREWALL_MODE）：
#   disable（默认）  实验环境直接关 firewalld，少踩坑
#   open            保留 firewalld，按节点角色放行 K8s 和 Calico 端口（生产思路）
#
# 支持 Rocky Linux 9（默认）和 Ubuntu 24.04
# 对应教程：Lab 05 K8s 集群搭建与日常维护
set -Eeuo pipefail

NODE_NAME="${NODE_NAME:-}"
NODE_IP="${NODE_IP:-}"
NODE_ROLE="${NODE_ROLE:-}"                 # master / worker，不填按主机名判断
FIREWALL_MODE="${FIREWALL_MODE:-disable}"
LAB_NET="${LAB_NET:-192.168.56}"           # 实验网段前三段，VMware / 云服务器按实际替换

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
  if [[ -z "$NODE_ROLE" ]]; then
    if [[ "$NODE_NAME" == *master* ]]; then NODE_ROLE=master; else NODE_ROLE=worker; fi
  fi
  if ! ip -4 addr | grep -q "inet ${NODE_IP}/"; then
    echo "本机网卡上没有 ${NODE_IP}，检查 NODE_IP 是否写错" >&2
    exit 2
  fi
}

set_hostname_and_hosts() {
  hostnamectl set-hostname "$NODE_NAME"
  # 先删掉旧的实验条目再写，脚本可以重复执行
  sed -i '/# ops-mall-lab05$/d' /etc/hosts
  cat >> /etc/hosts <<EOF
${LAB_NET}.21 k8s-master k8s-api.lab.local # ops-mall-lab05
${LAB_NET}.22 k8s-node1 # ops-mall-lab05
${LAB_NET}.23 k8s-node2 # ops-mall-lab05
${LAB_NET}.15 harbor.lab.local # ops-mall-lab05
EOF
  log INFO "主机名 ${NODE_NAME}，hosts 已写入（k8s-api.lab.local 指向 master）"
}

disable_swap() {
  # kubelet 默认检测到 swap 就拒绝启动
  swapoff -a
  sed -ri '/^[^#].*\sswap\s/s/^/#/' /etc/fstab
  # Rocky 9 一般没有 zram；Ubuntu / Fedora 系可能有，一并关掉
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
  log INFO "已加载 overlay、br_netfilter，开机自动加载"
}

set_sysctl() {
  cat > /etc/sysctl.d/99-k8s.conf <<EOF
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
  sysctl --system >/dev/null
  log INFO "ip_forward=$(sysctl -n net.ipv4.ip_forward) bridge-nf-call-iptables=$(sysctl -n net.bridge.bridge-nf-call-iptables)"
}

install_base_and_time() {
  if command -v dnf >/dev/null; then
    dnf install -y chrony curl tar conntrack-tools socat iproute-tc ipvsadm >/dev/null
    systemctl enable --now chronyd
  else
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq chrony curl tar conntrack socat ipvsadm >/dev/null
    systemctl enable --now chrony
  fi
  timedatectl set-timezone Asia/Shanghai
  # 证书和 etcd 都依赖时间一致，时间差太多会出现 x509 证书尚未生效
  chronyc makestep >/dev/null || true
  log INFO "chrony 已启动，时区 Asia/Shanghai"
}

set_selinux() {
  if command -v setenforce >/dev/null; then
    setenforce 0 || true
    sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
    log INFO "SELinux 已设为 permissive（kubeadm 官方安装文档的要求）"
  fi
}

set_firewall() {
  if ! systemctl list-unit-files 2>/dev/null | grep -q '^firewalld.service'; then
    if command -v ufw >/dev/null && [[ "$FIREWALL_MODE" == disable ]]; then
      ufw disable || true
    fi
    return 0
  fi
  if [[ "$FIREWALL_MODE" == disable ]]; then
    systemctl disable --now firewalld
    log INFO "firewalld 已关闭（实验取舍，生产用 FIREWALL_MODE=open）"
    return 0
  fi
  systemctl enable --now firewalld
  local ports=()
  if [[ "$NODE_ROLE" == master ]]; then
    ports+=(6443/tcp 2379-2380/tcp 10250/tcp 10257/tcp 10259/tcp)
  else
    ports+=(10250/tcp 10256/tcp 30000-32767/tcp 30000-32767/udp)
  fi
  # Calico：BGP 179、VXLAN 4789、Typha 5473
  ports+=(179/tcp 4789/udp 5473/tcp)
  local p
  for p in "${ports[@]}"; do
    firewall-cmd --permanent --add-port="$p" >/dev/null
  done
  # Pod 网段和 Service 网段之间的流量放行，否则跨节点 Pod 不通
  firewall-cmd --permanent --zone=trusted --add-source=10.244.0.0/16 >/dev/null
  firewall-cmd --permanent --zone=trusted --add-source=10.96.0.0/12 >/dev/null
  firewall-cmd --reload >/dev/null
  log INFO "firewalld 已放行 ${NODE_ROLE} 端口：${ports[*]}"
}

set_kubelet_node_ip() {
  # VirtualBox 每台机器都有一块 NAT 网卡（10.0.2.15），不指定的话 kubelet 会把它当节点 IP
  local f=/etc/sysconfig/kubelet
  [[ -d /etc/sysconfig ]] || f=/etc/default/kubelet
  echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" > "$f"
  log INFO "已写入 ${f}：--node-ip=${NODE_IP}"
}

main() {
  check_args
  set_hostname_and_hosts
  disable_swap
  load_modules
  set_sysctl
  install_base_and_time
  set_selinux
  set_firewall
  set_kubelet_node_ip
  log INFO "节点 ${NODE_NAME}（${NODE_ROLE}）准备完成，下一步 install-containerd.sh"
}

main "$@"
