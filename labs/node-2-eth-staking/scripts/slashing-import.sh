#!/usr/bin/env bash
# 在新机器上导入 slashing protection 数据。先导入 keystore（import-keys.sh），再执行本脚本，最后才启动 vc。
# 用法（新机器）：bash scripts/slashing-import.sh /path/to/slashing-protection-xxx.json
set -euo pipefail
# shellcheck source=common.sh
# common.sh 和本脚本在同一目录，单独做 shellcheck
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

src="${1:?用法：bash scripts/slashing-import.sh <交换文件.json>}"
[[ -f "$src" ]] || die "找不到 $src"
vc_running && die "lighthouse-vc 正在运行，导入前必须停止"
if [[ -f "$src.sha256" ]]; then
  echo "期望的 sha256：$(cut -d' ' -f1 "$src.sha256")"
fi
echo "实际的 sha256：$(sha256sum "$src" | cut -d' ' -f1)"
jq -e '.metadata.interchange_format_version' "$src" >/dev/null || die "不是 EIP-3076 交换格式文件"
echo "文件里包含 $(jq '.data | length' "$src") 个验证者的签名记录"
confirm "确认 sha256 一致、旧机器的 vc 已停止并禁用。"

name="$(basename "$src")"
sudo cp "$src" "$VC_DATA_DIR/$name"
docker run --rm -v "$VC_DATA_DIR":/data "$LIGHTHOUSE_IMAGE" \
  lighthouse --network hoodi --datadir /data account validator slashing-protection import "/data/$name"
echo
echo "导入完成。启动前再确认一次旧机器已停止，然后：docker compose --profile validator up -d"
echo "启动后 doppelganger 保护会先观察 3 个 epoch，期间不签名是正常的。"
