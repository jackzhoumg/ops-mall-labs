#!/usr/bin/env bash
# 从快照恢复节点数据（新机器快速上线，或数据库损坏后恢复）。
# 恢复后节点只需从快照时间点追到最新，通常几分钟到几十分钟，比从头同步快得多。
#
# 用法（目标机器）：
#   DATA_DIR=/data/eth bash scripts/snapshot-restore.sh /backup/eth/eth-node-20261124-030000.tar.zst
# 注意：会先把现有数据目录改名为 *.bak-<时间>，确认新数据正常后再手工删除。JWT 不在快照里，新机器先执行 gen-jwt.sh。
set -euo pipefail

archive="${1:?用法：bash snapshot-restore.sh <快照文件>}"
DATA_DIR="${DATA_DIR:-/data/eth}"
COMPOSE_DIR="${COMPOSE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
ts="$(date +%Y%m%d-%H%M%S)"

[[ -f "$archive" ]] || { echo "找不到 $archive" >&2; exit 1; }
if [[ -f "$archive.sha256" ]]; then
  echo "校验 sha256"
  sha256sum -c "$archive.sha256"
fi

read -r -p "将停止节点并替换 $DATA_DIR 下的 geth、lighthouse 数据，输入 yes 继续：" ans
[[ "$ans" == "yes" ]] || { echo "已取消"; exit 1; }

(cd "$COMPOSE_DIR" && docker compose stop lighthouse && docker compose stop -t 300 geth) || true

for d in geth lighthouse; do
  if sudo test -d "$DATA_DIR/$d"; then
    sudo mv "$DATA_DIR/$d" "$DATA_DIR/$d.bak-$ts"
  fi
done
echo "解压 $archive"
sudo tar -C "$DATA_DIR" --use-compress-program='zstd -T0 -d' -xf "$archive"

(cd "$COMPOSE_DIR" && docker compose up -d)
echo "已启动。用 bash scripts/sync-status.sh 观察追块；确认正常后删除 $DATA_DIR/*.bak-$ts"
