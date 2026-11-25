#!/usr/bin/env bash
# gameday-db-delay.sh：模拟事故演练用。在数据库机器上给 MySQL(3306) 和 Redis(6379) 的回包加延迟。
# 对应教程：SRE-4 故障演练与事故管理 5.7 节
#
# 为什么不用 Chaos Mesh 做这一步：NetworkChaos 只对注入时已经存在的 Pod 生效，Pod 一重建就“逃出”故障，
# 学员随手 rollout restart 就会误以为修好了。真实的网络故障不会因为 Pod 重启消失，所以在数据库那一侧注入。
#
# 用法（在 lab-db1 上用 root 执行，只有演练主持人执行）：
#   bash gameday-db-delay.sh start            # 默认延迟 1500ms，30 分钟后自动撤销
#   DELAY=800ms AUTO_REVERT=10m bash gameday-db-delay.sh start
#   bash gameday-db-delay.sh status
#   bash gameday-db-delay.sh stop             # 立即撤销
#
# 只影响源端口是 3306 / 6379 的出方向数据包，SSH 等其他流量不受影响。
# 依赖内核模块 sch_netem，Rocky Linux 9 要先装：dnf install -y kernel-modules-extra && modprobe sch_netem
set -euo pipefail

DELAY="${DELAY:-1500ms}"
JITTER="${JITTER:-100ms}"
AUTO_REVERT="${AUTO_REVERT:-30m}"
PORTS="${PORTS:-3306 6379}"
IFACE="${IFACE:-$(ip -o -4 addr show | awk '/192\.168\.56\./ { print $2; exit }')}"

[[ $EUID -eq 0 ]] || { echo "请用 root 执行" >&2; exit 1; }
[[ -n "$IFACE" ]] || { echo "找不到 192.168.56.x 网卡，用 IFACE=网卡名 指定" >&2; exit 1; }

start() {
  modprobe sch_netem 2>/dev/null || {
    echo "加载 sch_netem 失败。Rocky Linux 9：dnf install -y kernel-modules-extra 后重启或重新 modprobe" >&2
    exit 1
  }
  if tc qdisc show dev "$IFACE" | grep -q "netem"; then
    echo "网卡 $IFACE 上已经有 netem 规则，先 stop" >&2; exit 1
  fi
  # prio 队列有 3 个频段，默认流量走 1:1 / 1:2；只把匹配端口的包分到 1:3，再在 1:3 上挂 netem
  tc qdisc add dev "$IFACE" root handle 1: prio
  tc qdisc add dev "$IFACE" parent 1:3 handle 30: netem delay "$DELAY" "$JITTER"
  for p in $PORTS; do
    tc filter add dev "$IFACE" protocol ip parent 1:0 prio 3 u32 match ip sport "$p" 0xffff flowid 1:3
  done
  # 安全阀：到时间自动撤销，主持人忘了也不会一直坏下去
  systemd-run --unit=gameday-db-delay-revert --on-active="$AUTO_REVERT" \
    /usr/sbin/tc qdisc del dev "$IFACE" root >/dev/null
  echo "[$(date '+%F %T')] 已注入：$IFACE 源端口 $PORTS 延迟 $DELAY ± ${JITTER}，$AUTO_REVERT 后自动撤销"
}

stop() {
  tc qdisc del dev "$IFACE" root 2>/dev/null && echo "[$(date '+%F %T')] 已撤销 $IFACE 上的延迟" || echo "没有需要撤销的规则"
  systemctl stop gameday-db-delay-revert.timer 2>/dev/null || true
}

status() {
  tc qdisc show dev "$IFACE"
  tc filter show dev "$IFACE" 2>/dev/null || true
  systemctl list-timers gameday-db-delay-revert.timer --no-pager 2>/dev/null || true
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  *) echo "用法：$0 {start|stop|status}" >&2; exit 2 ;;
esac
