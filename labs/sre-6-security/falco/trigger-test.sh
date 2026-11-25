#!/usr/bin/env bash
# trigger-test.sh：故意做几件“可疑的事”，确认 Falco 能报出来。
# 对应教程：SRE-6 集群安全加固 5.6 节
#
# 用法（在 k8s-master 上执行）：
#   bash trigger-test.sh
#
# 会做：
#   1. kubectl exec 进 mall-web 执行 sh -c id         -> 触发自定义规则 Shell spawned in mall container
#   2. kubectl exec 进 mall-web 执行 cat /etc/shadow  -> 可能触发官方规则 Read sensitive file untrusted（文件没权限读时不触发）
# 然后到 mall-web 所在节点的 Falco Pod 日志里找告警。
set -euo pipefail

NS="${NS:-mall}"
FALCO_NS="${FALCO_NS:-falco}"

pod="$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=mall-web -o jsonpath='{.items[0].metadata.name}')"
node="$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.nodeName}')"
falco_pod="$(kubectl -n "$FALCO_NS" get pods -l app.kubernetes.io/name=falco \
  --field-selector "spec.nodeName=$node" -o jsonpath='{.items[0].metadata.name}')"

echo "目标 Pod：${pod}（节点 ${node}），对应 Falco Pod：$falco_pod"
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "== 1. 在容器里起 shell"
kubectl -n "$NS" exec "$pod" -- sh -c 'id; hostname' || true

echo "== 2. 读敏感文件"
kubectl -n "$NS" exec "$pod" -- cat /etc/shadow >/dev/null 2>&1 || true

echo "== 等 5 秒，查看 Falco 告警"
sleep 5
kubectl -n "$FALCO_NS" logs "$falco_pod" -c falco --since-time="$since" |
  grep -E '"rule":' | grep -E "$pod|mall" || {
  echo "没找到告警。检查：kubectl -n $FALCO_NS logs $falco_pod -c falco | tail -50"
  exit 1
}
