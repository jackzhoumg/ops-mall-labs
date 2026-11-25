#!/usr/bin/env bash
# 查看验证者在链上的状态：索引、状态（pending_queued / active_ongoing / exited_* ...）、余额。
# 用法（lab-eth1）：
#   bash scripts/validator-status.sh                 # 自动读 validator_definitions.yml 里的公钥
#   bash scripts/validator-status.sh 0xabc... 0xdef...
# 依赖：curl、jq
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

pubkeys=("$@")
if ((${#pubkeys[@]} == 0)); then
  defs="$VC_DATA_DIR/validators/validator_definitions.yml"
  sudo test -f "$defs" || die "找不到 ${defs}，传入公钥参数或先导入密钥"
  mapfile -t pubkeys < <(sudo grep -o 'voting_public_key: *"\{0,1\}0x[0-9a-fA-F]*' "$defs" | grep -o '0x[0-9a-fA-F]*')
fi
((${#pubkeys[@]} > 0)) || die "没有公钥"

ids="$(IFS=,; echo "${pubkeys[*]}")"
resp="$(curl -s -m 10 "$BN/eth/v1/beacon/states/head/validators?id=$ids")"
count="$(jq '.data | length' <<<"$resp" 2>/dev/null || echo 0)"
if [[ "$count" == "0" ]]; then
  echo "信标链上还查不到这些公钥：存款还没被处理（存款交易确认后通常要等十几分钟到数小时才会出现在信标链上），或公钥写错。"
  echo "也可以在浏览器看：https://hoodi.beaconcha.in/validator/${pubkeys[0]}"
  exit 0
fi
printf '%-8s %-22s %-14s %s\n' 索引 状态 余额ETH 公钥
jq -r '.data[] | [.index, .status, ((.balance | tonumber) / 1e9 | tostring), .validator.pubkey] | @tsv' <<<"$resp" |
  while IFS=$'\t' read -r idx st bal pk; do
    printf '%-8s %-22s %-14s %s\n' "$idx" "$st" "$bal" "${pk:0:18}..."
  done
echo
echo "浏览器查看：https://hoodi.beaconcha.in/validator/<索引>"
