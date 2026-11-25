#!/usr/bin/env bash
# 用 eval/questions.json 批量测 Dify 知识库的召回：期望的文档是否出现在前 K 条里（recall@K）。
# 调的是 Dify 知识库 API 的 retrieve 接口，只检索、不调对话模型，不花对话模型的钱（高质量索引会调一次 Embedding）。
# 用法：
#   DIFY_BASE=http://192.168.56.15:8088/v1 DIFY_DATASET_KEY=dataset-REPLACE_ME DIFY_DATASET_ID=<知识库 ID> \
#     bash dify/eval_recall.sh
# 可选：TOP_K（默认 4）、SEARCH_METHOD（默认 hybrid_search；没有 Embedding 模型时用 keyword_search）、MIN_RECALL（默认 0.8）
# 依赖：curl、jq
set -euo pipefail

: "${DIFY_BASE:?请设置 DIFY_BASE，例如 http://192.168.56.15:8088/v1}"
: "${DIFY_DATASET_KEY:?请设置 DIFY_DATASET_KEY（知识库 API 密钥，dataset- 开头）}"
: "${DIFY_DATASET_ID:?请设置 DIFY_DATASET_ID}"

questions="${QUESTIONS:-$(dirname "$0")/../eval/questions.json}"
top_k="${TOP_K:-4}"
method="${SEARCH_METHOD:-hybrid_search}"
min_recall="${MIN_RECALL:-0.8}"
api="${DIFY_BASE%/}/datasets/${DIFY_DATASET_ID}/retrieve"

total=0
hit=0
while IFS= read -r item; do
  q="$(jq -r '.question' <<<"$item")"
  want="$(basename "$(jq -r '.expect_source' <<<"$item")")"
  body="$(jq -nc --arg q "$q" --arg m "$method" --argjson k "$top_k" '{
    query: $q,
    retrieval_model: {search_method: $m, reranking_enable: false, top_k: $k, score_threshold_enabled: false}
  }')"
  resp="$(curl -sS -m 60 -X POST "$api" -H "Authorization: Bearer ${DIFY_DATASET_KEY}" \
    -H 'Content-Type: application/json' -d "$body")"
  if ! jq -e '.records' >/dev/null 2>&1 <<<"$resp"; then
    echo "检索失败：${q}：${resp}" >&2
    exit 1
  fi
  got="$(jq -r '[.records[].segment.document.name] | unique | join(", ")' <<<"$resp")"
  total=$((total + 1))
  if jq -e --arg w "$want" 'any(.records[]; .segment.document.name == $w)' >/dev/null <<<"$resp"; then
    hit=$((hit + 1))
    echo "[命中] ${q}"
  else
    echo "[未命中] ${q}  期望 ${want}，实际 ${got:-（无）}"
  fi
done < <(jq -c '.[]' "$questions")

recall="$(awk -v h="$hit" -v t="$total" 'BEGIN { printf "%.2f", (t ? h / t : 0) }')"
echo "recall@${top_k} = ${recall}（${hit}/${total}，检索方式 ${method}）"
# 低于阈值返回非零，可以放进 CI：有人改了 Runbook 或分段参数，召回掉了就拦下来
awk -v r="$recall" -v m="$min_recall" 'BEGIN { exit (r + 0 < m + 0) }'
