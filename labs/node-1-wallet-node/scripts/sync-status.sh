#!/usr/bin/env bash
# 查看执行层和共识层的同步状态、区块高度、对等节点数。
# 用法（lab-eth1）：bash scripts/sync-status.sh
#       EL=http://127.0.0.1:8545 CL=http://127.0.0.1:5052 bash scripts/sync-status.sh
# 依赖：curl、jq
set -euo pipefail

EL="${EL:-http://127.0.0.1:8545}"
CL="${CL:-http://127.0.0.1:5052}"

rpc() {
  curl -s -m 5 -X POST "$EL" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}"
}
hex2dec() { printf '%d' "$1"; }

echo "== 执行层（Geth）$EL"
syncing="$(rpc eth_syncing | jq -c '.result')"
if [[ "$syncing" == "false" ]]; then
  echo "同步状态：已同步"
else
  echo "同步状态：同步中 $syncing"
  cur="$(jq -r '.currentBlock // empty' <<<"$syncing")"
  high="$(jq -r '.highestBlock // empty' <<<"$syncing")"
  if [[ -n "$cur" && -n "$high" ]]; then
    echo "  当前 $(hex2dec "$cur") / 最高 $(hex2dec "$high")"
  fi
fi
block_hex="$(rpc eth_getBlockByNumber '["latest", false]' | jq -r '.result.number // "0x0"')"
ts_hex="$(rpc eth_getBlockByNumber '["latest", false]' | jq -r '.result.timestamp // "0x0"')"
peers_hex="$(rpc net_peerCount | jq -r '.result // "0x0"')"
chain_hex="$(rpc eth_chainId | jq -r '.result // "0x0"')"
now="$(date +%s)"
echo "链 ID：$(hex2dec "$chain_hex")（Hoodi=560048，Sepolia=11155111）"
echo "最新区块：$(hex2dec "$block_hex")，出块时间距今 $((now - $(hex2dec "$ts_hex"))) 秒"
echo "对等节点：$(hex2dec "$peers_hex")"

echo
echo "== 共识层（Lighthouse）$CL"
curl -s -m 5 "$CL/eth/v1/node/syncing" | jq '.data'
curl -s -m 5 "$CL/eth/v1/node/peer_count" | jq -c '.data'
curl -s -m 5 "$CL/eth/v1/beacon/states/head/finality_checkpoints" | jq -c '{finalized_epoch: .data.finalized.epoch}'
