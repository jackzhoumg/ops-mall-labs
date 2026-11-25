#!/usr/bin/env bash
# 节点数据快照备份：停 Geth / Lighthouse → 打包数据目录 → 启动。
# 为什么要停机：数据库在运行中不停写，直接拷贝得到的是不一致的文件，恢复后大概率要重新同步。
# 生产上用多节点轮流备份（先把这台从负载均衡摘掉），或者用 LVM / ZFS 快照把停机时间缩短到几十秒。
#
# 用法（lab-eth1，compose 部署）：
#   DATA_DIR=/data/eth BACKUP_DIR=/backup/eth bash scripts/snapshot-backup.sh
# 依赖：docker compose、tar、zstd
set -euo pipefail

DATA_DIR="${DATA_DIR:-/data/eth}"
BACKUP_DIR="${BACKUP_DIR:-/backup/eth}"
KEEP="${KEEP:-2}"
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
ts="$(date +%Y%m%d-%H%M%S)"
out="$BACKUP_DIR/eth-node-$ts.tar.zst"

command -v zstd >/dev/null || { echo "缺少 zstd：sudo dnf install -y zstd" >&2; exit 1; }
sudo mkdir -p "$BACKUP_DIR"

need_gb="$(sudo du -s --block-size=1G "$DATA_DIR/geth" "$DATA_DIR/lighthouse" | awk '{s+=$1} END {print s}')"
avail_gb="$(df -BG --output=avail "$BACKUP_DIR" | tail -1 | tr -dc '0-9')"
# zstd 一般能压到 60%-80%，按原始大小预留更稳
if ((avail_gb < need_gb)); then
  echo "备份盘可用 ${avail_gb}G，小于数据 ${need_gb}G，退出" >&2
  exit 1
fi

restart() {
  echo "启动节点"
  (cd "$COMPOSE_DIR" && docker compose start geth lighthouse)
}
trap restart EXIT

echo "停止节点（Geth 最多等 5 分钟刷盘）"
(cd "$COMPOSE_DIR" && docker compose stop lighthouse && docker compose stop -t 300 geth)

echo "打包到 $out"
start=$SECONDS
sudo tar -C "$DATA_DIR" --use-compress-program='zstd -T0 -3' -cf "$out" geth lighthouse
sudo sh -c "sha256sum '$out' > '$out.sha256'"
echo "完成：$(du -h "$out" | cut -f1)，耗时 $((SECONDS - start)) 秒"

# 只保留最近 KEEP 份
mapfile -t old < <(find "$BACKUP_DIR" -maxdepth 1 -name 'eth-node-*.tar.zst' -printf '%T@ %p\n' | sort -rn | tail -n +$((KEEP + 1)) | cut -d' ' -f2-)
for f in "${old[@]}"; do
  echo "删除旧备份 $f"
  sudo rm -f "$f" "$f.sha256"
done
