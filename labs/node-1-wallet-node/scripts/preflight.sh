#!/usr/bin/env bash
# 部署前检查：CPU / 内存 / 磁盘 / 时间同步 / 端口。不改任何东西，只报告。
# 用法（lab-eth1）：DATA_DIR=/data/eth bash scripts/preflight.sh
set -uo pipefail

DATA_DIR="${DATA_DIR:-/data/eth}"
MIN_DISK_GB="${MIN_DISK_GB:-400}"
fail=0
ok() { echo "[OK]   $*"; }
bad() { echo "[FAIL] $*"; fail=1; }
warn() { echo "[WARN] $*"; }

cpus="$(nproc)"
mem_gb="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)"
if ((cpus >= 4)); then ok "CPU $cpus 核"; else bad "CPU $cpus 核，至少 4 核"; fi
if ((mem_gb >= 15)); then ok "内存 ${mem_gb}G"; else bad "内存 ${mem_gb}G，至少 16G"; fi

mkdir_target="$DATA_DIR"
[[ -d "$mkdir_target" ]] || mkdir_target="$(dirname "$DATA_DIR")"
avail_gb="$(df -BG --output=avail "$mkdir_target" | tail -1 | tr -dc '0-9')"
if ((avail_gb >= MIN_DISK_GB)); then ok "$mkdir_target 可用 ${avail_gb}G"; else bad "$mkdir_target 可用 ${avail_gb}G，至少 ${MIN_DISK_GB}G"; fi
dev="$(df --output=source "$mkdir_target" | tail -1)"
rota="$(lsblk -ndo ROTA "$dev" 2>/dev/null | head -1)"
if [[ "$rota" == "1" ]]; then bad "$dev 是机械盘，同步会追不上链，换 SSD / NVMe"; else ok "$dev 不是机械盘"; fi

if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
  ok "时间已同步（NTP）"
else
  bad "时间没有同步：先看 timedatectl；建议 sudo apt install -y chrony（会替换掉默认的 systemd-timesyncd）。共识层对时间很敏感"
fi

for p in 30303 9000; do
  if ss -lntu | awk '{print $5}' | grep -qE "[:.]$p\$"; then
    warn "端口 $p 已被占用（如果是本节点自己在跑可以忽略）"
  else
    ok "端口 $p 空闲"
  fi
done

if command -v docker >/dev/null; then ok "docker $(docker --version | awk '{print $3}')"; else warn "没有 docker（用 systemd 方式部署可以忽略）"; fi
exit "$fail"
