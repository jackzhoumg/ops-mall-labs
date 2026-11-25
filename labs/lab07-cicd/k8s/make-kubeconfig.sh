#!/usr/bin/env bash
# 为 ci-deployer 生成只含自己权限的 kubeconfig
# 在 k8s-master 上用管理员 kubeconfig 执行：
#   bash labs/lab07-cicd/k8s/make-kubeconfig.sh
# 输出文件 ci-deployer.kubeconfig，内容整段粘贴到 GitLab 的 File 类型变量 KUBECONFIG_MALL，
# 或上传为 Jenkins 的 Secret file 凭据 kubeconfig-mall。用完删掉本地文件。
set -euo pipefail

NAMESPACE="${NAMESPACE:-mall}"
SA_NAME="${SA_NAME:-ci-deployer}"
SECRET_NAME="${SECRET_NAME:-ci-deployer-token}"
API_SERVER="${API_SERVER:-https://192.168.56.21:6443}"
OUT="${OUT:-ci-deployer.kubeconfig}"

# 等 token controller 把 token 写进 Secret
for _ in $(seq 1 10); do
  TOKEN="$(kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"
  [ -n "$TOKEN" ] && break
  sleep 1
done
if [ -z "${TOKEN:-}" ]; then
  echo "没拿到 token，先执行 kubectl apply -f labs/lab07-cicd/k8s/ci-deployer-rbac.yaml" >&2
  exit 1
fi

CA_FILE="$(mktemp)"
trap 'rm -f "$CA_FILE"' EXIT
kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA_FILE"

rm -f "$OUT"
kubectl config --kubeconfig="$OUT" set-cluster lab-k8s \
  --server="$API_SERVER" --certificate-authority="$CA_FILE" --embed-certs=true >/dev/null
kubectl config --kubeconfig="$OUT" set-credentials "$SA_NAME" --token="$TOKEN" >/dev/null
kubectl config --kubeconfig="$OUT" set-context "$SA_NAME@lab-k8s" \
  --cluster=lab-k8s --user="$SA_NAME" --namespace="$NAMESPACE" >/dev/null
kubectl config --kubeconfig="$OUT" use-context "$SA_NAME@lab-k8s" >/dev/null
chmod 600 "$OUT"

echo "已生成 ${OUT}，权限自检："
for check in "patch deployments" "get pods" "get secrets" "delete deployments"; do
  # shellcheck disable=SC2086
  printf '  %-20s %s\n' "$check" "$(kubectl --kubeconfig="$OUT" -n "$NAMESPACE" auth can-i $check || true)"
done
