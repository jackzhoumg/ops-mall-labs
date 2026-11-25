#!/usr/bin/env bash
# 导出 slashing protection 数据（EIP-3076 交换格式），用于迁移验证者到另一台机器或另一个客户端。
# 会先停止本机的 validator，并确认它真的停了——导出时 vc 必须是停止状态，否则导出的数据不是最新的。
# 用法（旧机器）：bash scripts/slashing-export.sh
# 输出：$VC_DATA_DIR/slashing-protection-<时间>.json 及其 sha256
set -euo pipefail
# shellcheck source=common.sh
# common.sh 和本脚本在同一目录，单独做 shellcheck
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

confirm "将停止本机 lighthouse-vc 并导出 slashing protection 数据。停止后验证者会开始离线扣分。"
(cd "$COMPOSE_DIR" && docker compose --profile validator stop validator)
sleep 2
vc_running && die "lighthouse-vc 仍在运行，停止失败"

# 禁止自动拉起：restart: unless-stopped 下 stop 后不会自动重启，这里再把容器删掉，防止有人误 start
(cd "$COMPOSE_DIR" && docker compose --profile validator rm -f validator)

ts="$(date +%Y%m%d-%H%M%S)"
out="/data/slashing-protection-$ts.json"
docker run --rm -v "$VC_DATA_DIR":/data "$LIGHTHOUSE_IMAGE" \
  lighthouse --network hoodi --datadir /data account validator slashing-protection export "$out"

host_file="$VC_DATA_DIR/slashing-protection-$ts.json"
sudo sha256sum "$host_file" | sudo tee "$host_file.sha256"
echo
echo "已导出：$host_file"
echo "下一步（见 docs/migration-checklist.md）："
echo "  1. 在旧机器上禁用 validator：把 compose.yaml 里 validator 的 profile 改名或删掉，防止重启后又被拉起"
echo "  2. 把这个 json 和 keystore 一起拷到新机器（scp），核对 sha256"
echo "  3. 至少等 2 个 epoch（约 13 分钟），并在浏览器确认验证者已经开始 missed attestation（说明旧机器真的停了）"
