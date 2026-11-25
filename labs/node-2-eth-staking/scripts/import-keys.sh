#!/usr/bin/env bash
# 把 ethstaker-deposit-cli 生成的 keystore 导入 Lighthouse 验证者客户端。
# 用法（lab-eth1）：bash scripts/import-keys.sh /path/to/validator_keys
# 过程中会逐个要求输入 keystore 密码，并询问是否把密码保存到 validator_definitions.yml：
#   保存：vc 重启后自动加载，不会因为没人输密码而一直离线；代价是密码以明文存在本机
#   不保存：每次启动都要人工输入，掉线时间可能很长。测试网建议保存，并保证数据目录权限 700
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

keys_dir="${1:?用法：bash scripts/import-keys.sh <validator_keys 目录>}"
[[ -d "$keys_dir" ]] || die "目录不存在：$keys_dir"
keys_dir="$(cd "$keys_dir" && pwd)"
compgen -G "$keys_dir/keystore-m_*.json" >/dev/null || die "$keys_dir 下没有 keystore-m_*.json"

if vc_running; then
  die "lighthouse-vc 正在运行，先 docker compose --profile validator stop validator"
fi

echo "将导入以下 keystore 到 ${VC_DATA_DIR}（Hoodi）："
ls -1 "$keys_dir"/keystore-m_*.json
echo
echo "检查清单："
echo "  1. 这些密钥没有在任何其他机器、任何其他客户端上运行过，或者旧机器已经确认停掉并迁移了 slashing protection 数据"
echo "  2. 这是 Hoodi 测试网的密钥（deposit_data 里 network_name 是 hoodi）"
grep -ho '"network_name": *"[a-z]*"' "$keys_dir"/deposit_data-*.json 2>/dev/null | sort -u || true
confirm "确认以上两点。"

sudo mkdir -p "$VC_DATA_DIR"
sudo chmod 700 "$VC_DATA_DIR"
docker run --rm -it \
  -v "$VC_DATA_DIR":/data \
  -v "$keys_dir":/keys:ro \
  "$LIGHTHOUSE_IMAGE" \
  lighthouse --network hoodi --datadir /data account validator import --directory /keys

echo
echo "导入完成。下一步：docker compose --profile validator up -d，然后看日志里的 Enabled validator 和 doppelganger 检测。"
echo "原始 keystore 目录导入后建议从这台机器删除（离线介质上的备份保留）。"
