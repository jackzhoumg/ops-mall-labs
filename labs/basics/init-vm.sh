#!/usr/bin/env bash
# init-vm.sh：实验虚拟机初始化脚本（Ubuntu Server 24.04 LTS，amd64 / arm64 都能用）
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
#   1. 设置主机名（同时改 /etc/hosts 里 127.0.1.1 那一行）
#   2. 在 /etc/hosts 里写入课程约定的全部主机名和域名（网段取自你给的 IP 的前三段）
#   3. 软件源换成阿里云镜像，写 DEB822 格式的 /etc/apt/sources.list.d/ubuntu.sources
#      （原文件备份到 /etc/apt/backup-<时间>/；amd64 用 ubuntu，arm64 用 ubuntu-ports）
#   4. 安装常用工具，设置时区 Asia/Shanghai，开启 systemd-timesyncd 时间同步
#   5. 确保 ops 用户存在并在 sudo 组
#   6. ufw 防火墙：放行 SSH 后开启；AppArmor 保持开启（见下面的说明）
#   7. 最后用 netplan 把 Host-Only 网卡配成静态 IP（如果你正通过旧 IP 的 SSH 连着，连接会断，用新 IP 重连即可）
#
# 可选环境变量：
#   LAB_IFACE=enp0s8        指定要配静态 IP 的网卡。不指定时自动找：已有同网段 IP 的网卡 > 唯一一块没有默认路由的物理网卡
#   LAB_PREFIX=24           子网掩码位数，默认 24
#   LAB_SKIP_IP=1           不改 IP。云服务器一定要设这个，云服务器的内网 IP 由云平台分配
#   LAB_SKIP_APPLY=1        写好 netplan 配置并用 netplan generate 检查，但不立即生效（之后手动 netplan apply 或重启）
#   LAB_SKIP_MIRROR=1       不换软件源（云服务器一般已经配好了云厂商内网源）
#   LAB_MIRROR_URL=...      镜像地址，默认按架构选 https://mirrors.aliyun.com/ubuntu 或 .../ubuntu-ports
#   LAB_FIREWALL=on         on（默认，开启 ufw 并放行 SSH）或 off（关闭 ufw）
#   LAB_MALL_HOST=10        mall.lab.local 指向网段里的哪个地址：10（默认，Lab 02-03 的 VIP）或 200（Lab 06 起的 K8s 网关）
#
# ---------------------------------------------------------------------------
# 关于 ufw 和 AppArmor：为什么默认把 ufw 打开、AppArmor 不关
#
# Ubuntu 装完后 ufw 是关着的（inactive），AppArmor 是开着的。网上很多教程第一步是
# “关掉所有安全机制”。实验环境这么做确实省事，但学员会养成“出问题先关安全机制”的习惯；
# 到了公司，生产机器的主机防火墙或云安全组多半是开着的，安全检查也会扫。
#
# 所以本课程的取舍：
#   - ufw：默认开启，只放行 SSH（OpenSSH 这个应用配置，即 22/tcp）。一定是先放行 SSH 再开启，
#     顺序反了会把自己锁在外面。后面每个实验用到哪个端口就放行哪个端口，
#     例如 Lab 02 的 sudo ufw allow 80/tcp。
#     代价：新手会遇到“本机 curl 正常、别的机器访问超时”，这正好是要练的排错点。
#     不想要这个代价的（例如纯内网、只有自己用的实验机），用 LAB_FIREWALL=off。
#     Lab 05 搭 K8s 时节点之间端口很多、Calico 也有自己的规则，那一课会说明为什么
#     K8s 节点上通常不开 ufw、改用云安全组或网络策略控制访问。
#   - AppArmor：Ubuntu 默认开启，脚本不改它，只打印状态。遇到被拦截时看
#     journalctl -k | grep apparmor（或 /var/log/syslog 里的 apparmor="DENIED"），
#     针对那一个程序调整配置文件，而不是整体关掉。
# ---------------------------------------------------------------------------
set -euo pipefail

PREFIX="${LAB_PREFIX:-24}"
FIREWALL_MODE="${LAB_FIREWALL:-on}"
MALL_HOST="${LAB_MALL_HOST:-10}"
LAB_USER="ops"
NETPLAN_FILE="/etc/netplan/60-ops-lab.yaml"
SOURCES_FILE="/etc/apt/sources.list.d/ubuntu.sources"

PACKAGES=(
  vim bash-completion man-db less
  curl wget tar unzip rsync tree jq lsof
  git tcpdump bind9-dnsutils netcat-openbsd traceroute iproute2 iputils-ping
  systemd-timesyncd sysstat ufw shellcheck
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
# BEGIN ops-mall lab hosts (managed by ansible)
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
# END ops-mall lab hosts (managed by ansible)
EOF
}

# 打印 DEB822 格式的软件源。写法来自阿里云镜像站 Ubuntu 页面的“DEB822 配置方法”
print_sources() {
  local url="$1"
  cat <<EOF
# 由 labs/basics/init-vm.sh 生成（阿里云镜像，DEB822 格式）。原文件备份在 /etc/apt/backup-*/
Types: deb
URIs: ${url}
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${url}
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
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
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
  die "本脚本只支持 Ubuntu 24.04 LTS，当前系统：${PRETTY_NAME:-未知}"
fi
case "$FIREWALL_MODE" in on|off) ;; *) die "LAB_FIREWALL 只能是 on 或 off" ;; esac

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) DEFAULT_MIRROR="https://mirrors.aliyun.com/ubuntu" ;;
  arm64) DEFAULT_MIRROR="https://mirrors.aliyun.com/ubuntu-ports" ;;
  *) die "不支持的架构：${ARCH}（只支持 amd64 和 arm64）" ;;
esac
MIRROR_URL="${LAB_MIRROR_URL:-$DEFAULT_MIRROR}"
export DEBIAN_FRONTEND=noninteractive

log "系统：${PRETTY_NAME}（${ARCH}），目标：${NEW_HOSTNAME} / ${NEW_IP}/${PREFIX}"

# ---------- 0. 克隆机：重置 machine-id 和 SSH 主机密钥 ----------
# 克隆出来的机器和原机器 machine-id 一样。Ubuntu 的 systemd-networkd 用 machine-id 生成 DHCP 客户端标识，
# 所以就算 MAC 地址不同，DHCP 也可能分到同一个 IP；日志 / 监控系统也会把两台当成一台。
# SSH 主机密钥一样，等于两台机器共用一张“身份证”。
if [[ $CLONE -eq 1 ]]; then
  log "重置 machine-id"
  rm -f /etc/machine-id
  systemd-machine-id-setup
  log "重新生成 SSH 主机密钥"
  rm -f /etc/ssh/ssh_host_*
  ssh-keygen -A
  # Ubuntu 24.04 的 sshd 默认由 ssh.socket 按需拉起，服务名是 ssh（不是 sshd）
  systemctl try-restart ssh.service || true
  warn "SSH 主机密钥变了，在你自己电脑上执行：ssh-keygen -R ${NEW_IP} 清掉旧记录再重连"
fi

# ---------- 1. 主机名 ----------
log "设置主机名为 ${NEW_HOSTNAME}"
hostnamectl set-hostname "$NEW_HOSTNAME"
# 云服务器上 cloud-init 可能在重启时把主机名改回去，告诉它保留我们设置的主机名
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
  printf '# 由 labs/basics/init-vm.sh 生成\npreserve_hostname: true\n' > /etc/cloud/cloud.cfg.d/99-ops-lab.cfg
fi

# ---------- 2. /etc/hosts ----------
log "写入 /etc/hosts（网段 ${NET}.0/24，mall.lab.local -> ${NET}.${MALL_HOST}）"
tmp_hosts="$(mktemp)"
# 先删掉旧的课程区块和旧的 127.0.1.1 行，再写新的，保证重复执行不会越写越多。
# Ubuntu 安装时会写一行“127.0.1.1 <主机名>”，主机名改了这一行不跟着改，留着就是一条指向回环地址的过期记录。
# 本机主机名已经在课程区块里、并且指向本机静态 IP（如 192.168.56.11 lab-web1）时，就不再写 127.0.1.1：
# 否则 getent hosts lab-web1 在本机会先返回 127.0.1.1，依赖“主机名解析到本机 IP”的程序会拿到回环地址。
# 这也是 Debian 文档的建议：有固定 IP 的机器，用固定 IP 代替 127.0.1.1。
sed -e '/^# BEGIN ops-mall lab hosts (managed by ansible)$/,/^# END ops-mall lab hosts (managed by ansible)$/d' \
    -e '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts > "$tmp_hosts"
{
  if ! print_hosts "$NET" | awk -v ip="$NEW_IP" -v h="$NEW_HOSTNAME" \
       '$1 == ip { for (i = 2; i <= NF; i++) if ($i == h) found = 1 } END { exit !found }'; then
    printf '127.0.1.1 %s\n' "$NEW_HOSTNAME"
  fi
  cat "$tmp_hosts"
  print_hosts "$NET"
} > "${tmp_hosts}.new"
# 用 cat 覆盖而不是 mv：保留 /etc/hosts 原来的属主和权限
cat "${tmp_hosts}.new" > /etc/hosts
rm -f "$tmp_hosts" "${tmp_hosts}.new"

# ---------- 3. 软件源 ----------
# Ubuntu 24.04 的源配置是 DEB822 格式的 /etc/apt/sources.list.d/ubuntu.sources，
# /etc/apt/sources.list 只剩一行注释。照着老教程改 sources.list 不会生效，还可能和 ubuntu.sources 重复。
if [[ "${LAB_SKIP_MIRROR:-0}" == "1" ]]; then
  log "跳过换源（LAB_SKIP_MIRROR=1）"
else
  tmp_src="$(mktemp)"
  print_sources "$MIRROR_URL" > "$tmp_src"
  if [[ -f "$SOURCES_FILE" ]] && cmp -s "$tmp_src" "$SOURCES_FILE"; then
    log "软件源已经是 ${MIRROR_URL}，不用改"
  elif [[ -f "$SOURCES_FILE" ]] && ! grep -Eq '^URIs:.*(archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com|mirrors\.aliyun\.com)' "$SOURCES_FILE"; then
    # 云厂商或公司自己改过的源（比如云内网源），不碰
    log "${SOURCES_FILE} 指向的不是官方源，保持不动：$(grep -m1 '^URIs:' "$SOURCES_FILE" || true)"
  else
    if [[ -f "$SOURCES_FILE" ]]; then
      # 备份放在 sources.list.d 外面：apt 会读 sources.list.d 下所有 .sources 文件，备份放里面会变成重复的源
      backup_dir="/etc/apt/backup-$(date +%Y%m%d%H%M%S)"
      mkdir -p "$backup_dir"
      cp -a "$SOURCES_FILE" "$backup_dir/"
      log "原始源文件备份在 ${backup_dir}"
    fi
    cat "$tmp_src" > "$SOURCES_FILE"
    chmod 644 "$SOURCES_FILE"
    log "已换源：${SOURCES_FILE} -> ${MIRROR_URL}"
  fi
  rm -f "$tmp_src"
  if grep -Eq '^[[:space:]]*deb' /etc/apt/sources.list 2>/dev/null; then
    warn "/etc/apt/sources.list 里还有生效的 deb 行（老系统升级上来的？），可能和 ubuntu.sources 重复，建议注释掉"
  fi
fi
apt-get update

# ---------- 4. 常用工具、时区、时间同步 ----------
# apt-get install 只要有一个包名找不到就整条失败，所以先挑出源里有的包
to_install=()
not_found=()
for p in "${PACKAGES[@]}"; do
  if apt-cache show "$p" >/dev/null 2>&1; then to_install+=("$p"); else not_found+=("$p"); fi
done
log "安装常用工具：${to_install[*]}"
apt-get install -y --no-install-recommends "${to_install[@]}"
if [[ ${#not_found[@]} -gt 0 ]]; then
  warn "这些包在源里找不到：${not_found[*]}，检查软件源后可手动 apt install"
fi

# Ubuntu 24.04 默认用 systemd-timesyncd 做时间同步，实验机够用；需要对外提供 NTP 服务时才换 chrony
log "时区设为 Asia/Shanghai，开启时间同步（systemd-timesyncd）"
timedatectl set-timezone Asia/Shanghai
timedatectl set-ntp true || warn "开启时间同步失败（容器里没有时钟权限时会这样），虚拟机上请检查 timedatectl status"

# ---------- 5. ops 用户 ----------
if id "$LAB_USER" >/dev/null 2>&1; then
  log "用户 ${LAB_USER} 已存在"
else
  log "创建用户 ${LAB_USER}"
  useradd -m -s /bin/bash "$LAB_USER"
  warn "记得给 ${LAB_USER} 设置密码：sudo passwd ${LAB_USER}（没有密码时 sudo 用不了）"
fi
# Ubuntu 的 /etc/sudoers 默认允许 sudo 组使用 sudo；安装时创建的第一个用户已经在这个组里
usermod -aG sudo "$LAB_USER"

# 云服务器通常只给 root 或默认用户 ubuntu 配了公钥，复制一份给 ops，方便直接用 ops 登录
if [[ ! -s "/home/${LAB_USER}/.ssh/authorized_keys" ]]; then
  for src in /root/.ssh/authorized_keys /home/ubuntu/.ssh/authorized_keys; do
    [[ -s "$src" ]] || continue
    log "把 ${src} 复制给 ${LAB_USER}"
    install -d -m 700 -o "$LAB_USER" -g "$LAB_USER" "/home/${LAB_USER}/.ssh"
    install -m 600 -o "$LAB_USER" -g "$LAB_USER" "$src" "/home/${LAB_USER}/.ssh/authorized_keys"
    break
  done
fi

# ---------- 6. ufw 和 AppArmor ----------
if [[ "$FIREWALL_MODE" == "on" ]]; then
  log "ufw：先放行 SSH，再开启"
  # OpenSSH 是 openssh-server 自带的 ufw 应用配置（/etc/ufw/applications.d/openssh-server），即 22/tcp
  if ufw app info OpenSSH >/dev/null 2>&1; then
    ufw allow OpenSSH >/dev/null
  else
    ufw allow 22/tcp >/dev/null
  fi
  ufw --force enable >/dev/null
  # ufw enable 只加载规则，不会启动 ufw.service；这里一起启用，保证开机自动加载、systemctl 看到的状态也一致
  systemctl enable --now ufw >/dev/null 2>&1 || true
  ufw status | sed 's/^/        /'
else
  warn "ufw：按 LAB_FIREWALL=off 关闭。只建议在纯内网实验机上这么做"
  ufw disable >/dev/null || true
fi

if command -v aa-enabled >/dev/null 2>&1 && aa-enabled --quiet 2>/dev/null; then
  log "AppArmor：已开启，保持不变"
else
  warn "AppArmor 当前没有开启（容器里是正常的；虚拟机上请检查 systemctl status apparmor）"
fi

# ---------- 7. 静态 IP（netplan） ----------
if [[ "${LAB_SKIP_IP:-0}" == "1" ]]; then
  log "跳过 IP 配置（LAB_SKIP_IP=1）"
  log "完成。重新登录后提示符会显示新主机名。"
  exit 0
fi
command -v netplan >/dev/null 2>&1 || die "找不到 netplan 命令（Ubuntu Server 默认自带）。先 apt install -y netplan.io"

default_iface="$(ip -4 route show default | awk '{print $5; exit}')"
iface="${LAB_IFACE:-}"
if [[ -z "$iface" ]]; then
  # 优先：已经有同网段 IP 的网卡（比如 Host-Only 网卡 DHCP 拿到了 192.168.56.101）
  iface="$(ip -4 -o addr show | awk -v net="${NET}." 'index($4, net) == 1 {print $2; exit}')"
fi
if [[ -z "$iface" ]]; then
  # 其次：唯一一块不带默认路由的物理网卡（NAT 网卡带默认路由，Host-Only 网卡不带）
  candidates=()
  for d in /sys/class/net/*; do
    n="${d##*/}"
    [[ -e "$d/device" && "$n" != "${default_iface:-none}" ]] && candidates+=("$n")
  done
  if [[ ${#candidates[@]} -eq 1 ]]; then
    iface="${candidates[0]}"
  fi
fi
[[ -n "$iface" ]] || die "找不到要配置的网卡。先用 ip -br addr 看网卡名，再用 LAB_IFACE=网卡名 重新执行"
ip link show "$iface" >/dev/null 2>&1 || die "网卡 ${iface} 不存在"

# 课程只写自己的 60-ops-lab.yaml，不改安装程序生成的 50-cloud-init.yaml。
# netplan 按文件名顺序读取 /etc/netplan/*.yaml，后读的覆盖先读的同名设置，
# 所以 60 里的 dhcp4: false 会盖掉 50 里的 dhcp4: true。
tmp_np="$(mktemp)"
if [[ "$iface" == "$default_iface" ]]; then
  # 单网卡（UTM Shared Network、桥接）：这块网卡同时负责上网，要保留网关和 DNS
  gw="$(ip -4 route show default dev "$iface" | awk '{print $3; exit}')"
  [[ -n "$gw" ]] || die "${iface} 上找不到默认网关，无法安全地改成静态 IP"
  dns="$(resolvectl dns "$iface" 2>/dev/null | awk -F': ' '{print $2}' | xargs || true)"
  dns="${dns:-$gw}"
  log "${iface} 是上网网卡，保留网关 ${gw}，DNS ${dns}"
  cat > "$tmp_np" <<EOF
# 由 labs/basics/init-vm.sh 生成，重复执行会整个覆盖
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp4: false
      addresses:
        - ${NEW_IP}/${PREFIX}
      routes:
        - to: default
          via: ${gw}
      nameservers:
        addresses: [${dns// /, }]
EOF
else
  # Host-Only 网卡只负责和其他虚拟机、宿主机通信，不能配网关，否则会和 NAT 网卡抢默认路由
  cat > "$tmp_np" <<EOF
# 由 labs/basics/init-vm.sh 生成，重复执行会整个覆盖
# Host-Only 网卡：只配地址，不配网关（上网走 NAT 网卡）
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp4: false
      addresses:
        - ${NEW_IP}/${PREFIX}
EOF
fi

old_np=""
if [[ -f "$NETPLAN_FILE" ]]; then
  old_np="$(mktemp)"
  cp -a "$NETPLAN_FILE" "$old_np"
fi
install -m 600 "$tmp_np" "$NETPLAN_FILE"     # netplan 要求配置文件只有 root 能读，权限太宽会警告
rm -f "$tmp_np"
log "网卡 ${iface} 配置为 ${NEW_IP}/${PREFIX}，写入 ${NETPLAN_FILE}"

# 先 generate 检查语法，有错就还原，不让一份坏配置留在 /etc/netplan 里
if ! netplan generate; then
  if [[ -n "$old_np" ]]; then cp -a "$old_np" "$NETPLAN_FILE"; else rm -f "$NETPLAN_FILE"; fi
  rm -f "$old_np"
  die "netplan generate 失败，已还原 ${NETPLAN_FILE}"
fi
rm -f "$old_np"

if [[ "${LAB_SKIP_APPLY:-0}" == "1" ]]; then
  log "LAB_SKIP_APPLY=1：配置已写好并通过 netplan generate 检查，没有立即生效。确认无误后执行 sudo netplan apply"
  exit 0
fi

cat <<EOF
[init] 初始化完成，即将应用新 IP（netplan apply）。
[init] 如果你正通过 SSH 连着这台机器的旧 IP，连接会断开，这是正常的。
[init] 用新地址重连：ssh ${LAB_USER}@${NEW_IP}
[init] 重连后自检：hostnamectl; ip -br addr; getent hosts lab-db1; apt-cache policy | head; sudo ufw status
EOF
netplan apply
# 新地址生效前稍等一下
for _ in 1 2 3 4 5; do
  ip -4 -o addr show dev "$iface" | grep -q "${NEW_IP}/" && break
  sleep 1
done
log "当前 ${iface} 地址：$(ip -4 -o addr show dev "$iface" | awk '{print $4}' | xargs)"
