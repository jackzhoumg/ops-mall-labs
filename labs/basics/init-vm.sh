#!/usr/bin/env bash
# init-vm.sh：实验虚拟机初始化脚本（Rocky Linux 9，x86_64 / aarch64 都能用）
# 对应教程：入门基础包 基础-1 实验环境搭建
#
# 用法（在虚拟机上用 root 或 sudo 执行）：
#   sudo bash init-vm.sh <主机名> <IP>              # 新装的虚拟机
#   sudo bash init-vm.sh --clone <主机名> <IP>      # 克隆出来的虚拟机（额外重置 machine-id 和 SSH 主机密钥）
#   bash init-vm.sh --print-hosts 192.168.56         # 只打印 hosts 内容，给自己电脑的 hosts 文件用
#   注意：<IP> 是“要配置成的静态 IP”，不是虚拟机现在 DHCP 拿到的 IP
#
# 例子：
#   sudo bash init-vm.sh lab-web1 192.168.56.11
#   sudo bash init-vm.sh lab-web1 192.168.64.11     # Apple Silicon + UTM，网段按实际替换
#
# 脚本做的事（每一步都可以重复执行，执行两次结果一样）：
#   1. 设置主机名
#   2. 在 /etc/hosts 里写入课程约定的全部主机名和域名（网段取自你给的 IP 的前三段）
#   3. 软件源换成阿里云 Rocky Linux 镜像（原文件备份到 /etc/yum.repos.d/backup-<时间>/）
#   4. 安装常用工具，设置时区 Asia/Shanghai，开启 chronyd 时间同步
#   5. 确保 ops 用户存在并在 wheel 组（有 sudo 权限）
#   6. 按约定处理 firewalld 和 SELinux（默认都保持开启，见下面的说明）
#   7. 最后把 Host-Only 网卡配成静态 IP（如果你正通过旧 IP 的 SSH 连着，连接会断，用新 IP 重连即可）
#
# 可选环境变量：
#   LAB_IFACE=enp0s8        指定要配静态 IP 的网卡。不指定时自动找：已有同网段 IP 的网卡 > 唯一一块没有默认路由的网卡
#   LAB_PREFIX=24           子网掩码位数，默认 24
#   LAB_SKIP_IP=1           不改 IP。云服务器一定要设这个，云服务器的内网 IP 由云平台分配
#   LAB_SKIP_MIRROR=1       不换软件源（云服务器一般已经配好了云厂商内网源）
#   LAB_MIRROR_URL=...      镜像地址，默认 https://mirrors.aliyun.com/rockylinux
#   LAB_SELINUX=enforcing   enforcing（默认）或 permissive，不提供 disabled
#   LAB_FIREWALL=on         on（默认）或 off
#   LAB_MALL_HOST=10        mall.lab.local 指向网段里的哪个地址：10（默认，Lab 02-03 的 VIP）或 200（Lab 06 起的 K8s 网关）
#
# ---------------------------------------------------------------------------
# 关于 firewalld 和 SELinux：为什么不“一上来先全关掉”
#
# 网上很多教程第一步就是 systemctl disable firewalld + 把 SELinux 改成 disabled。
# 实验环境这么做确实省事，但有两个问题：
#   - 学员会养成“出问题先关安全机制”的习惯。到了公司，生产环境这两样多半是开着的，
#     安全检查也会扫这两项。不会在开着的情况下排错，是真实工作里的短板。
#   - SELinux 设成 disabled 以后再想打开，要给整个文件系统重新打标签（relabel），
#     重启要很久，还可能起不来。permissive 模式只记录不拦截，随时能切回来。
#
# 所以本课程的取舍：
#   - SELinux：默认保持 enforcing。遇到被拦截时先看 /var/log/audit/audit.log，
#     用 semanage / restorecon / setsebool 正确放行（Lab 02 会练）。
#     实在要临时排除 SELinux 的影响，用 LAB_SELINUX=permissive，不要用 disabled。
#   - firewalld：默认保持开启，只放行 ssh。后面每个实验用到哪个端口就放行哪个端口，
#     例如 Lab 02 的 firewall-cmd --permanent --add-service=http。
#     Lab 05 搭 K8s 时，节点之间端口很多、Calico 也有自己的规则，
#     那一课会说明为什么 K8s 节点上通常关闭 firewalld、改用云安全组或网络策略控制访问。
# ---------------------------------------------------------------------------
set -euo pipefail

MIRROR_URL="${LAB_MIRROR_URL:-https://mirrors.aliyun.com/rockylinux}"
PREFIX="${LAB_PREFIX:-24}"
SELINUX_MODE="${LAB_SELINUX:-enforcing}"
FIREWALL_MODE="${LAB_FIREWALL:-on}"
MALL_HOST="${LAB_MALL_HOST:-10}"
LAB_USER="ops"

PACKAGES=(
  vim-enhanced bash-completion man-pages
  curl wget tar unzip rsync tree jq lsof
  git tcpdump bind-utils nmap-ncat traceroute iproute
  chrony sysstat policycoreutils-python-utils
)

log()  { printf '\033[32m[init]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# 打印 hosts 内容。参数：网段前三段，例如 192.168.56
print_hosts() {
  local net="$1"
  cat <<EOF
# >>> ops-mall lab hosts >>>
# 由 labs/basics/init-vm.sh 生成，重复执行会整块替换。网段：${net}.0/24
${net}.11  lab-web1
${net}.12  lab-web2
${net}.13  lab-db1
${net}.14  lab-db2
${net}.15  lab-dev harbor.lab.local
${net}.16  lab-ci gitlab.lab.local jenkins.lab.local
${net}.21  k8s-master
${net}.22  k8s-node1
${net}.23  k8s-node2
${net}.31  lab-eth1
${net}.32  lab-eth2
# K8s 网关入口（MetalLB 分给 lab-gateway 的地址，Lab 06 起可用）
${net}.200 argocd.lab.local grafana.lab.local prometheus.lab.local alertmanager.lab.local
${net}.200 kibana.lab.local loki.lab.local jaeger.lab.local
${net}.200 mall-staging.lab.local mall-prod.lab.local
# mall.lab.local：Lab 02-03 指向 Keepalived VIP ${net}.10；Lab 06 起改成 K8s 网关入口 ${net}.200
# 切换：LAB_MALL_HOST=200 重新执行本脚本，或者手动改下面这一行
${net}.${MALL_HOST} mall.lab.local
# <<< ops-mall lab hosts <<<
EOF
}

valid_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    (( 10#$o <= 255 )) || return 1
  done
}

valid_hostname() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

case "$MALL_HOST" in 10|200) ;; *) die "LAB_MALL_HOST 只能是 10 或 200" ;; esac

# ---------- 参数 ----------
CLONE=0
if [[ "${1:-}" == "--print-hosts" ]]; then
  [[ -n "${2:-}" ]] || die "用法：$0 --print-hosts 192.168.56"
  print_hosts "$2"
  exit 0
fi
if [[ "${1:-}" == "--clone" ]]; then
  CLONE=1
  shift
fi
[[ $# -eq 2 ]] || usage

NEW_HOSTNAME="$1"
NEW_IP="$2"
valid_hostname "$NEW_HOSTNAME" || die "主机名不合法：${NEW_HOSTNAME}（只用小写字母、数字、中划线，如 lab-web1）"
valid_ipv4 "$NEW_IP" || die "IP 不合法：${NEW_IP}"
if ! [[ "$PREFIX" =~ ^[0-9]+$ ]] || (( PREFIX < 8 || PREFIX > 30 )); then
  die "LAB_PREFIX 不合法：${PREFIX}（一般就是 24）"
fi
NET="${NEW_IP%.*}"

[[ $EUID -eq 0 ]] || die "请用 root 执行：sudo bash $0 $*"
[[ -r /etc/os-release ]] || die "找不到 /etc/os-release"
# shellcheck source=/dev/null
. /etc/os-release
if [[ "${ID:-}" != "rocky" || "${VERSION_ID%%.*}" != "9" ]]; then
  die "本脚本只支持 Rocky Linux 9，当前系统：${PRETTY_NAME:-未知}。Ubuntu 的做法见教程里的对照命令。"
fi
case "$SELINUX_MODE" in enforcing|permissive) ;; *) die "LAB_SELINUX 只能是 enforcing 或 permissive" ;; esac
case "$FIREWALL_MODE" in on|off) ;; *) die "LAB_FIREWALL 只能是 on 或 off" ;; esac

log "系统：${PRETTY_NAME}（$(uname -m)），目标：${NEW_HOSTNAME} / ${NEW_IP}/${PREFIX}"

# ---------- 0. 克隆机：重置 machine-id 和 SSH 主机密钥 ----------
# 克隆出来的机器和原机器 machine-id 一样，DHCP 可能分到同一个 IP，日志 / 监控系统也会把两台当成一台。
# SSH 主机密钥一样，等于两台机器共用一张“身份证”。
if [[ $CLONE -eq 1 ]]; then
  log "重置 machine-id"
  rm -f /etc/machine-id
  systemd-machine-id-setup
  log "重新生成 SSH 主机密钥"
  rm -f /etc/ssh/ssh_host_*
  ssh-keygen -A
  systemctl restart sshd
  warn "SSH 主机密钥变了，在你自己电脑上执行：ssh-keygen -R ${NEW_IP} 清掉旧记录再重连"
fi

# ---------- 1. 主机名 ----------
log "设置主机名为 ${NEW_HOSTNAME}"
hostnamectl set-hostname "$NEW_HOSTNAME"

# ---------- 2. /etc/hosts ----------
log "写入 /etc/hosts（网段 ${NET}.0/24，mall.lab.local -> ${NET}.${MALL_HOST}）"
tmp_hosts="$(mktemp)"
# 先删掉旧的课程区块，再追加新的，保证重复执行不会越写越多
sed '/^# >>> ops-mall lab hosts >>>$/,/^# <<< ops-mall lab hosts <<<$/d' /etc/hosts > "$tmp_hosts"
print_hosts "$NET" >> "$tmp_hosts"
# 用 cat 覆盖而不是 mv：保留 /etc/hosts 原来的权限和 SELinux 标签
cat "$tmp_hosts" > /etc/hosts
rm -f "$tmp_hosts"

# ---------- 3. 软件源 ----------
# 写法来自阿里云镜像站 Rocky Linux 页面（developer.aliyun.com/mirror/rockylinux）：
#   注释掉 mirrorlist，把 #baseurl=http://dl.rockylinux.org/$contentdir 换成镜像地址。
# 镜像站页面上写的是 /etc/yum.repos.d/Rocky-*.repo，那是 Rocky 8 的文件名；
# Rocky 9 的文件是小写的 rocky.repo、rocky-extras.repo 等，所以这里匹配 rocky*.repo。
if [[ "${LAB_SKIP_MIRROR:-0}" == "1" ]]; then
  log "跳过换源（LAB_SKIP_MIRROR=1）"
else
  changed=0
  backup_dir="/etc/yum.repos.d/backup-$(date +%Y%m%d%H%M%S)"
  for f in /etc/yum.repos.d/rocky*.repo; do
    [[ -e "$f" ]] || continue
    # 只改还指向官方地址的文件；已经换过源或者是云厂商改过的，不碰
    # 单引号是故意的：要匹配文件里字面上的 $contentdir
    # shellcheck disable=SC2016
    if grep -q '^#baseurl=http://dl.rockylinux.org/\$contentdir' "$f"; then
      mkdir -p "$backup_dir"
      cp -a "$f" "$backup_dir/"
      sed -e 's|^mirrorlist=|#mirrorlist=|g' \
          -e "s|^#baseurl=http://dl.rockylinux.org/\$contentdir|baseurl=${MIRROR_URL}|g" \
          -i "$f"
      changed=1
      log "已换源：${f}"
    fi
  done
  if [[ $changed -eq 1 ]]; then
    # 备份放在子目录里：dnf 只读 /etc/yum.repos.d/*.repo，不会读到备份，避免重复的源
    log "原始源文件备份在 ${backup_dir}"
  else
    log "没有需要换源的文件（可能已经换过）"
  fi
  dnf clean all >/dev/null
  dnf makecache
fi

# ---------- 4. 常用工具、时区、时间同步 ----------
log "安装常用工具：${PACKAGES[*]}"
# strict=0：某个包在源里找不到时跳过它，而不是整条命令失败
dnf install -y --setopt=strict=0 "${PACKAGES[@]}"
missing=()
for p in "${PACKAGES[@]}"; do
  rpm -q "$p" >/dev/null 2>&1 || missing+=("$p")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  warn "这些包没装上：${missing[*]}，检查软件源后可手动 dnf install"
fi

log "时区设为 Asia/Shanghai，开启 chronyd"
timedatectl set-timezone Asia/Shanghai
systemctl enable --now chronyd

# ---------- 5. ops 用户 ----------
if id "$LAB_USER" >/dev/null 2>&1; then
  log "用户 ${LAB_USER} 已存在"
else
  log "创建用户 ${LAB_USER}"
  useradd -m -s /bin/bash "$LAB_USER"
  warn "记得给 ${LAB_USER} 设置密码：sudo passwd ${LAB_USER}（没有密码时 sudo 用不了）"
fi
# Rocky 的 /etc/sudoers 默认已经允许 wheel 组使用 sudo
usermod -aG wheel "$LAB_USER"

# 云服务器通常只给 root 配了公钥，复制一份给 ops，方便直接用 ops 登录
if [[ -s /root/.ssh/authorized_keys && ! -s "/home/${LAB_USER}/.ssh/authorized_keys" ]]; then
  log "把 root 的 authorized_keys 复制给 ${LAB_USER}"
  install -d -m 700 -o "$LAB_USER" -g "$LAB_USER" "/home/${LAB_USER}/.ssh"
  install -m 600 -o "$LAB_USER" -g "$LAB_USER" /root/.ssh/authorized_keys "/home/${LAB_USER}/.ssh/authorized_keys"
  restorecon -R "/home/${LAB_USER}/.ssh" || true
fi

# ---------- 6. firewalld 和 SELinux ----------
if [[ "$FIREWALL_MODE" == "on" ]]; then
  log "firewalld：保持开启，放行 ssh"
  systemctl enable --now firewalld
  firewall-cmd --permanent --add-service=ssh >/dev/null
  firewall-cmd --reload >/dev/null
else
  warn "firewalld：按 LAB_FIREWALL=off 关闭。只建议在纯内网实验机上这么做"
  systemctl disable --now firewalld || true
fi

current_selinux="$(getenforce 2>/dev/null || echo Unknown)"
if [[ "$current_selinux" == "Disabled" ]]; then
  warn "SELinux 当前是 Disabled，脚本不自动打开（需要 relabel 并重启），按教程手动处理"
else
  log "SELinux：设置为 ${SELINUX_MODE}（当前 ${current_selinux}）"
  sed -i "s/^SELINUX=.*/SELINUX=${SELINUX_MODE}/" /etc/selinux/config
  if [[ "$SELINUX_MODE" == "enforcing" ]]; then setenforce 1; else setenforce 0; fi
fi

# ---------- 7. 静态 IP ----------
if [[ "${LAB_SKIP_IP:-0}" == "1" ]]; then
  log "跳过 IP 配置（LAB_SKIP_IP=1）"
  log "完成。重新登录后提示符会显示新主机名。"
  exit 0
fi

default_iface="$(ip -4 route show default | awk '{print $5; exit}')"
iface="${LAB_IFACE:-}"
if [[ -z "$iface" ]]; then
  # 优先：已经有同网段 IP 的网卡（比如 Host-Only 网卡 DHCP 拿到了 192.168.56.101）
  iface="$(ip -4 -o addr show | awk -v net="${NET}." 'index($4, net) == 1 {print $2; exit}')"
fi
if [[ -z "$iface" ]]; then
  # 其次：唯一一块不带默认路由的以太网卡（NAT 网卡带默认路由，Host-Only 网卡不带）
  mapfile -t candidates < <(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2 == "ethernet" {print $1}' | grep -vx "${default_iface:-none}" || true)
  if [[ ${#candidates[@]} -eq 1 ]]; then
    iface="${candidates[0]}"
  fi
fi
[[ -n "$iface" ]] || die "找不到要配置的网卡。先用 ip a 看网卡名，再用 LAB_IFACE=网卡名 重新执行"
ip link show "$iface" >/dev/null 2>&1 || die "网卡 ${iface} 不存在"

conn="$(nmcli -g GENERAL.CONNECTION device show "$iface" 2>/dev/null || true)"
if [[ -z "$conn" || "$conn" == "--" ]]; then
  conn="$iface"
  if ! nmcli -t -f NAME connection show | grep -qx "$conn"; then
    log "为 ${iface} 新建连接 ${conn}"
    nmcli connection add type ethernet ifname "$iface" con-name "$conn"
  fi
fi

mod_args=(ipv4.method manual ipv4.addresses "${NEW_IP}/${PREFIX}" connection.autoconnect yes)
if [[ "$iface" == "$default_iface" ]]; then
  # 单网卡（UTM Shared Network、桥接）：这块网卡同时负责上网，要保留网关和 DNS
  gw="$(ip -4 route show default dev "$iface" | awk '{print $3; exit}')"
  dns="$(nmcli -g IP4.DNS device show "$iface" | tr '|' ' ' | xargs)"
  [[ -n "$gw" ]] || die "${iface} 上找不到默认网关，无法安全地改成静态 IP"
  dns="${dns:-$gw}"
  mod_args+=(ipv4.gateway "$gw" ipv4.dns "$dns")
  log "${iface} 是上网网卡，保留网关 ${gw}，DNS ${dns}"
else
  # Host-Only 网卡只负责和其他虚拟机、宿主机通信，不能配网关，否则会和 NAT 网卡抢默认路由
  mod_args+=(ipv4.gateway "" ipv4.never-default yes)
fi

log "网卡 ${iface}（连接名 ${conn}）配置为 ${NEW_IP}/${PREFIX}"
nmcli connection modify "$conn" "${mod_args[@]}"

cat <<EOF
[init] 初始化完成，即将应用新 IP。
[init] 如果你正通过 SSH 连着这台机器的旧 IP，连接会断开，这是正常的。
[init] 用新地址重连：ssh ${LAB_USER}@${NEW_IP}
[init] 重连后自检：hostnamectl; ip -4 addr; getent hosts lab-db1; dnf repolist
EOF
nmcli connection up "$conn" >/dev/null
log "新 IP 已生效：$(ip -4 -o addr show dev "$iface" | awk '{print $4}' | xargs)"
