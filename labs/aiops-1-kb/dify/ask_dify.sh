#!/usr/bin/env bash
# 调用 Dify 聊天助手应用的 API，打印回答和引用来源。
# 用法：DIFY_BASE=http://192.168.56.15:8088/v1 DIFY_APP_KEY=app-xxx bash ask_dify.sh "问题"
# 依赖：curl、jq
set -euo pipefail

: "${DIFY_BASE:?请设置 DIFY_BASE，例如 http://192.168.56.15:8088/v1}"
: "${DIFY_APP_KEY:?请设置 DIFY_APP_KEY（应用的 API 密钥，app- 开头）}"
question="${1:?用法：bash ask_dify.sh \"问题\"}"

body="$(jq -n --arg q "$question" '{inputs: {}, query: $q, response_mode: "blocking", user: "ops-cli"}')"

resp="$(curl -sS -m 120 -X POST "$DIFY_BASE/chat-messages" \
  -H "Authorization: Bearer $DIFY_APP_KEY" \
  -H 'Content-Type: application/json' \
  -d "$body")"

if ! jq -e '.answer' >/dev/null 2>&1 <<<"$resp"; then
  echo "调用失败：$resp" >&2
  exit 1
fi

jq -r '.answer' <<<"$resp"
echo
echo "参考来源："
jq -r '.metadata.retriever_resources // [] | .[] | "- \(.document_name)  score=\(.score)"' <<<"$resp"
