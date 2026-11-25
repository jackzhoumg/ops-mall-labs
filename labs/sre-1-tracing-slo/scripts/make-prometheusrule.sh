#!/usr/bin/env bash
# 把标准 Prometheus 规则文件包装成 kube-prometheus-stack 认的 PrometheusRule 资源，输出到标准输出。
#
# 用法（k8s-master，在 labs/sre-1-tracing-slo 目录下）：
#   bash scripts/make-prometheusrule.sh slo/rules/mall-api-slo.rules.yml | kubectl apply -f -
#   bash scripts/make-prometheusrule.sh slo/sloth/generated/mall-api.rules.yml mall-api-slo-sloth | kubectl apply -f -
#
# 环境变量：
#   RULE_NAMESPACE  PrometheusRule 放在哪个命名空间，默认 monitoring
#   RELEASE_LABEL   kube-prometheus-stack 的 release 名，Prometheus 只加载带 release=<它> 标签的规则，
#                   默认 kube-prometheus-stack。查法：
#                   kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.ruleSelector}'
set -euo pipefail

rules_file="${1:?用法: $0 <规则文件> [资源名]}"
name="${2:-mall-api-slo}"
ns="${RULE_NAMESPACE:-monitoring}"
release="${RELEASE_LABEL:-kube-prometheus-stack}"

if [[ ! -f "$rules_file" ]]; then
  echo "找不到规则文件: $rules_file" >&2
  exit 1
fi

cat <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    release: ${release}
    app.kubernetes.io/name: mall-api
    app.kubernetes.io/part-of: ops-mall
spec:
EOF
# 去掉 --- 和注释行，其余每行缩进两格放到 spec 下面
grep -v -e '^---' -e '^[[:space:]]*#' "$rules_file" | sed 's/^/  /'
