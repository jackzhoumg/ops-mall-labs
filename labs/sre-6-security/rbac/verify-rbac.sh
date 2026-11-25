#!/usr/bin/env bash
# verify-rbac.sh：用 kubectl auth can-i 逐条验证三类账号的权限是否符合预期。
# 对应教程：SRE-6 集群安全加固 5.3 节
#
# 用法（在 k8s-master 上，用管理员 kubeconfig 执行。管理员才有 impersonate 权限）：
#   bash verify-rbac.sh
#
# 原理：--as / --as-group 是“扮演”某个用户 / 组去问 API Server，不需要真的有他的证书。
# 每一行：期望结果 账号 动作。实际和期望不一致就标 FAIL，最后退出码 1。
set -uo pipefail

fail=0

check() {
  local expect="$1" who="$2"
  shift 2
  local -a as_args
  case "$who" in
    dev) as_args=(--as=dev-zhang --as-group=mall-dev) ;;
    ops) as_args=(--as=ops-li --as-group=ops-readonly) ;;
    ci) as_args=(--as=system:serviceaccount:mall:ci-deployer) ;;
    *)
      echo "未知账号 $who" >&2
      exit 2
      ;;
  esac
  local got
  got="$(kubectl auth can-i "$@" "${as_args[@]}" 2>/dev/null || true)"
  if [[ "$got" == "$expect" ]]; then
    printf '[PASS] %-4s %-3s %s\n' "$who" "$got" "$*"
  else
    printf '[FAIL] %-4s 期望 %s 实际 %s：%s\n' "$who" "$expect" "${got:-error}" "$*"
    fail=1
  fi
}

echo "== 开发 dev-zhang（组 mall-dev）"
check yes dev get pods -n mall
check yes dev get pods --subresource=log -n mall
check yes dev create pods --subresource=portforward -n mall
check yes dev patch deployments -n mall
check no dev get secrets -n mall
check no dev create pods --subresource=exec -n mall
check no dev delete deployments -n mall
check no dev get pods -n kube-system
check no dev create rolebindings -n mall

echo "== 只读运维 ops-li（组 ops-readonly）"
check yes ops get pods -A
check yes ops get nodes
check yes ops list deployments -n kube-system
check yes ops get clusterrolebindings
check no ops get secrets -n mall
check no ops delete pods -n mall
check no ops patch deployments -n mall
check no ops create pods --subresource=exec -n mall

echo "== CI 账号 ci-deployer"
check yes ci patch deployments/mall-api -n mall
check yes ci get deployments/mall-web -n mall
check yes ci list replicasets -n mall
check no ci patch deployments/other-app -n mall
check no ci create deployments -n mall
check no ci delete deployments/mall-api -n mall
check no ci get secrets -n mall
check no ci patch deployments/mall-api -n mall-prod

echo
if [[ "$fail" -eq 0 ]]; then
  echo "全部符合预期"
else
  echo "有不符合预期的权限，检查 Role / RoleBinding"
fi
exit "$fail"
