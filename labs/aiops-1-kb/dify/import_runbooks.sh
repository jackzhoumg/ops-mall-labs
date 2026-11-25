#!/usr/bin/env bash
# 把 runbooks/ 下的 Markdown 批量导入 Dify 知识库（Dify 知识库 API，create-by-file）。
# 同名文档已存在时先删除再导入，所以 Runbook 更新后重复执行即可（可以放进 Runbook 仓库的 CI）。
# 用法：
#   DIFY_BASE=http://192.168.56.15:8088/v1 DIFY_DATASET_KEY=dataset-REPLACE_ME DIFY_DATASET_ID=<知识库 ID> \
#     bash dify/import_runbooks.sh [目录，默认 runbooks/]
# DIFY_DATASET_KEY 在 Dify「知识库 → API」里创建（dataset- 开头），和应用的 app- 密钥不是一个东西。
# 依赖：curl、jq
set -euo pipefail

: "${DIFY_BASE:?请设置 DIFY_BASE，例如 http://192.168.56.15:8088/v1}"
: "${DIFY_DATASET_KEY:?请设置 DIFY_DATASET_KEY（知识库 API 密钥，dataset- 开头）}"
: "${DIFY_DATASET_ID:?请设置 DIFY_DATASET_ID（知识库 ID，在知识库页面的地址栏里）}"

dir="${1:-$(dirname "$0")/../runbooks}"
# high_quality 要求工作空间已配置 Embedding 模型；没有模型时可以先用 economy（关键词索引）走通流程
indexing="${DIFY_INDEXING:-high_quality}"
api="${DIFY_BASE%/}/datasets/${DIFY_DATASET_ID}"
auth=(-H "Authorization: Bearer ${DIFY_DATASET_KEY}")

# 分段规则和代码方式一致：按二级标题切，最长 800，重叠 100
data="$(jq -nc --arg t "$indexing" '{
  indexing_technique: $t,
  doc_form: "text_model",
  process_rule: {
    mode: "custom",
    rules: {
      pre_processing_rules: [
        {id: "remove_extra_spaces", enabled: true},
        {id: "remove_urls_emails", enabled: false}
      ],
      segmentation: {separator: "\n## ", max_tokens: 800, chunk_overlap: 100}
    }
  }
}')"

count=0
while IFS= read -r -d '' f; do
  name="$(basename "$f")"
  # 先记下同名的旧文档，新文档导入成功后再删，导入失败时旧版本还在
  old_ids="$(curl -sS -m 30 -G "${api}/documents" "${auth[@]}" \
    --data-urlencode "keyword=${name}" --data-urlencode "limit=100" |
    jq -r --arg n "$name" '.data // [] | .[] | select(.name == $n) | .id')"

  resp="$(curl -sS -m 120 -X POST "${api}/document/create-by-file" "${auth[@]}" \
    -F "data=${data};type=text/plain" -F "file=@${f};type=text/markdown")"
  if ! jq -e '.document.id' >/dev/null 2>&1 <<<"$resp"; then
    echo "导入失败：${name}：${resp}" >&2
    exit 1
  fi
  echo "已导入：${name}  batch=$(jq -r '.batch' <<<"$resp")"
  count=$((count + 1))

  for id in $old_ids; do
    curl -sS -m 30 -o /dev/null -X DELETE "${api}/documents/${id}" "${auth[@]}"
    echo "  已删除旧版本 ${id}"
  done
done < <(find "$dir" -type f -name '*.md' -print0 | sort -z)

echo "共导入 ${count} 个文件。到 Dify 知识库页面看状态变成「可用」，或调用 ${api}/documents 查看 indexing_status"
