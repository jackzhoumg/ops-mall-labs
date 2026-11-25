#!/usr/bin/env bash
# preflight-check.sh：演练前自动检查（演练前检查清单里能自动化的部分）。
# 对应教程：SRE-4 故障演练与事故管理
#
# 用法（在 k8s-master 上执行，需要 kubectl 权限）：
#   bash preflight-check.sh
#   NS=mall APP=mall-api bash preflight-check.sh
#
# 任意一项 FAIL 就退出码 1：先修好再演练。WARN 不阻止，但要在演练记录里写明。
set -uo pipefail

NS="${NS:-mall}"
APP="${APP:-mall-api}"
fail=0

pass() { printf '[PASS] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
bad() {
  printf '[FAIL] %s\n' "$*"
  fail=1
}

command -v kubectl >/dev/null || {
  echo "需要 kubectl" >&2
  exit 2
}

# 1. 集群可达，节点都 Ready
if ! kubectl get nodes >/dev/null 2>&1; then
  bad "kubectl 连不上集群"
  exit 1
fi
notready="$(kubectl get nodes --no-headers | awk '$2 !~ /^Ready/ { print $1 }')"
if [[ -z "$notready" ]]; then
  pass "所有节点 Ready"
else
  bad "节点未就绪：$notready"
fi

# 2. 目标应用副本数 >= 2 且全部可用
desired="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
ready="$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
ready="${ready:-0}"
if [[ -z "$desired" ]]; then
  bad "找不到 deployment/${APP}（命名空间 ${NS}）"
elif [[ "$desired" -lt 2 ]]; then
  bad "$APP 只有 $desired 个副本，杀 Pod 会直接中断服务。先执行 kubectl -n $NS scale deploy $APP --replicas=2"
elif [[ "$ready" -lt "$desired" ]]; then
  bad "$APP 就绪 $ready/${desired}，系统本身就不健康，不要演练"
else
  pass "$APP 副本 $ready/$desired 全部就绪"
fi

# 3. 副本分布在不同节点
nodes="$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=$APP" \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | grep -c . || true)"
if [[ "${nodes:-0}" -ge 2 ]]; then
  pass "$APP 分布在 $nodes 个节点"
else
  warn "$APP 的 Pod 都在同一个节点，节点故障会全挂（考虑 topologySpreadConstraints）"
fi

# 4. 有 PDB
if kubectl -n "$NS" get pdb -o jsonpath='{range .items[*]}{.spec.selector.matchLabels}{"\n"}{end}' 2>/dev/null | grep -q "$APP"; then
  pass "$APP 有 PodDisruptionBudget"
else
  warn "$APP 没有 PDB（kubectl apply -f k8s/mall-api-pdb.yaml）"
fi

# 5. 没有残留的混沌实验
leftover="$(kubectl -n "$NS" get podchaos,networkchaos,stresschaos,schedule --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$leftover" -eq 0 ]]; then
  pass "命名空间 $NS 没有残留的混沌实验"
else
  bad "命名空间 $NS 还有 $leftover 个混沌实验，先清理：bash abort.sh"
fi

# 6. Chaos Mesh 组件正常（READY 列分子等于分母，STATUS 是 Running）
if kubectl -n chaos-mesh get pods --no-headers 2>/dev/null |
  awk 'BEGIN { n = 0 } { n++; split($2, a, "/"); if ($3 != "Running" || a[1] != a[2]) bad = 1 } END { exit (bad || n == 0) }'; then
  pass "Chaos Mesh 组件全部 Running"
else
  bad "Chaos Mesh 组件不正常或没装：kubectl -n chaos-mesh get pods"
fi

# 7. 监控在线
if kubectl -n monitoring get pods --no-headers 2>/dev/null | grep -q prometheus; then
  pass "monitoring 命名空间有 Prometheus"
else
  warn "没找到 Prometheus，演练时看不到指标，只能靠 steady-state.sh"
fi

# 8. 故障接口开关
debug="$(kubectl -n "$NS" get deploy "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MALL_DEBUG")].value}' 2>/dev/null || true)"
if [[ "$debug" == "true" ]]; then
  warn "MALL_DEBUG=true：故障接口已打开，演练结束记得关掉"
else
  pass "MALL_DEBUG 未开启（要用故障接口时再开）"
fi

echo
if [[ "$fail" -eq 0 ]]; then
  echo "预检通过，可以开始演练。别忘了在群里发演练开始通知。"
else
  echo "预检未通过，先处理 FAIL 项。"
fi
exit "$fail"
