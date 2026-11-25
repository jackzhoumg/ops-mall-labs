#!/usr/bin/env bash
# Lab 10（选做）：初始化 Elasticsearch / Kibana
#   1. ILM 生命周期策略：mall-* 索引 7 天后删除
#   2. 索引模板：mall-* 单副本为 0（单节点集群）、关联 ILM、关键字段的类型
#   3. 写入账号 fluentbit：只能往 mall-* 写，不能读、不能删
#   4. Kibana 空间 mall + 只读角色 mall_log_reader + 账号 mall-dev：按业务线隔离查看权限
#   5. Kibana 数据视图 mall-*
#
# 用法（k8s-master，Elasticsearch 和 Kibana 都 Ready 之后）：
#   ./setup-es.sh
# 会生成两个随机密码：fluentbit 的写到 Secret logging/fluent-bit-es，mall-dev 的打印在屏幕上。
set -euo pipefail

NS=logging
ES_POD=mall-logs-es-default-0
KIBANA_URL=http://mall-kibana-kb-http.${NS}.svc:5601

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

ELASTIC_PW="$(kubectl -n "$NS" get secret mall-logs-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)"
[[ -n "$ELASTIC_PW" ]] || { echo "拿不到 elastic 用户密码，Elasticsearch 装好了吗？"; exit 1; }

# es <方法> <路径> [JSON 从标准输入读]：在 ES Pod 里用 curl 调接口，不用把 9200 端口暴露出来
es() {
  kubectl -n "$NS" exec -i "$ES_POD" -c elasticsearch -- \
    curl -s --fail-with-body -u "elastic:${ELASTIC_PW}" -X "$1" "http://localhost:9200$2" \
    -H 'Content-Type: application/json' --data-binary @-
  echo
}

# kb <方法> <路径>：调 Kibana 接口，Kibana 要求带 kbn-xsrf 请求头
kb() {
  kubectl -n "$NS" exec -i "$ES_POD" -c elasticsearch -- \
    curl -s -u "elastic:${ELASTIC_PW}" -X "$1" "${KIBANA_URL}$2" \
    -H 'Content-Type: application/json' -H 'kbn-xsrf: true' --data-binary @-
  echo
}

log "1. 创建 ILM 策略 mall-logs-7d"
es PUT /_ilm/policy/mall-logs-7d <<'EOF'
{
  "policy": {
    "phases": {
      "hot":    { "min_age": "0ms", "actions": { "set_priority": { "priority": 100 } } },
      "delete": { "min_age": "7d",  "actions": { "delete": {} } }
    }
  }
}
EOF

log "2. 创建索引模板 mall-logs（匹配 mall-*）"
es PUT /_index_template/mall-logs <<'EOF'
{
  "index_patterns": ["mall-*"],
  "priority": 200,
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0,
      "index.lifecycle.name": "mall-logs-7d"
    },
    "mappings": {
      "properties": {
        "request_id":  { "type": "keyword" },
        "route":       { "type": "keyword" },
        "path":        { "type": "keyword" },
        "method":      { "type": "keyword" },
        "level":       { "type": "keyword" },
        "msg":         { "type": "keyword" },
        "status":      { "type": "integer" },
        "duration_ms": { "type": "float" }
      }
    }
  }
}
EOF

log "3. 创建写入角色和 fluentbit 账号"
es PUT /_security/role/fluentbit_writer <<'EOF'
{
  "cluster": ["monitor"],
  "indices": [
    { "names": ["mall-*"], "privileges": ["create_index", "create_doc", "auto_configure"] }
  ]
}
EOF
FB_PW="$(openssl rand -hex 16)"
es POST /_security/user/fluentbit <<EOF
{ "password": "${FB_PW}", "roles": ["fluentbit_writer"], "full_name": "Fluent Bit writer" }
EOF
kubectl -n "$NS" create secret generic fluent-bit-es \
  --from-literal=ES_PASSWORD="${FB_PW}" --dry-run=client -o yaml | kubectl apply -f -

log "4. 创建 Kibana 空间 mall、只读角色 mall_log_reader、账号 mall-dev"
kb POST /api/spaces/space <<'EOF'
{ "id": "mall", "name": "商城业务线", "disabledFeatures": [] }
EOF
kb PUT /api/security/role/mall_log_reader <<'EOF'
{
  "elasticsearch": {
    "indices": [ { "names": ["mall-*"], "privileges": ["read", "view_index_metadata"] } ]
  },
  "kibana": [ { "base": ["read"], "spaces": ["mall"] } ]
}
EOF
DEV_PW="$(openssl rand -hex 8)"
es POST /_security/user/mall-dev <<EOF
{ "password": "${DEV_PW}", "roles": ["mall_log_reader"], "full_name": "商城开发（只读）" }
EOF

log "5. 在 mall 空间创建数据视图 mall-*"
kb POST /s/mall/api/data_views/data_view <<'EOF'
{ "data_view": { "title": "mall-*", "name": "mall 日志", "timeFieldName": "@timestamp" } }
EOF

log "完成。Kibana：http://kibana.lab.local"
log "管理员：elastic / ${ELASTIC_PW}"
log "只读账号：mall-dev / ${DEV_PW}（只能看 mall 空间里 mall-* 索引）"
