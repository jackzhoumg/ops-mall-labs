#!/usr/bin/env bash
# Lab 09：检查告警规则语法并跑单元测试
# 依赖：promtool（Prometheus 发布包里自带）、yq（https://github.com/mikefarah/yq，v4）
# 用法：cd labs/lab09-monitoring/tests && ./run-rule-tests.sh
set -euo pipefail
cd "$(dirname "$0")"

command -v promtool >/dev/null || { echo "找不到 promtool：从 Prometheus Release 包解压出来放进 PATH"; exit 1; }
command -v yq >/dev/null || { echo "找不到 yq：brew install yq 或从 GitHub Release 下载"; exit 1; }

mkdir -p build
# PrometheusRule 是 K8s 对象，promtool 只认里面的 spec（groups 列表），先抽出来
yq '.spec' ../manifests/prometheusrule-mall-api.yaml >build/mall-api.rules.yaml
yq '.spec' ../manifests/prometheusrule-infra.yaml >build/infra.rules.yaml

promtool check rules build/mall-api.rules.yaml build/infra.rules.yaml
promtool test rules rules.test.yaml
