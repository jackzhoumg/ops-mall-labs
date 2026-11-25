#!/usr/bin/env bash
# create-user-kubeconfig.sh：用 Kubernetes CSR API 给一个人签发客户端证书，生成他专用的 kubeconfig。
# 对应教程：SRE-6 集群安全加固 5.3 节
#
# 用法（在 k8s-master 上，用管理员 kubeconfig 执行）：
#   bash create-user-kubeconfig.sh dev-zhang mall-dev           # 用户名 dev-zhang，组 mall-dev
#   bash create-user-kubeconfig.sh ops-li ops-readonly
#   DAYS=30 bash create-user-kubeconfig.sh dev-zhang mall-dev   # 证书有效期 30 天（默认 90）
#
# 生成：./users/<用户名>.key（私钥，只给本人）、./users/<用户名>.kubeconfig
# Kubernetes 没有“用户”对象：证书里的 CN 就是用户名，O 就是组。删除用户 = 等证书过期（或轮换 CA），
# 所以有效期别设太长，人员离职要能及时失效，生产环境更推荐接 OIDC（企业 SSO）。
set -euo pipefail

user="${1:-}"
group="${2:-}"
DAYS="${DAYS:-90}"
[[ -n "$user" && -n "$group" ]] || {
  echo "用法：$0 <用户名> <组>" >&2
  exit 2
}

command -v openssl >/dev/null || {
  echo "需要 openssl" >&2
  exit 2
}

outdir="./users"
mkdir -p "$outdir"
chmod 700 "$outdir"
key="$outdir/$user.key"
csr="$outdir/$user.csr"
crt="$outdir/$user.crt"
kcfg="$outdir/$user.kubeconfig"

# 1. 生成私钥和证书签名请求（CSR）
openssl genrsa -out "$key" 3072 2>/dev/null
chmod 600 "$key"
openssl req -new -key "$key" -out "$csr" -subj "/CN=$user/O=$group"

# 2. 提交给集群签名
kubectl delete csr "$user" --ignore-not-found >/dev/null
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $user
spec:
  request: $(base64 <"$csr" | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: $((DAYS * 86400))
  usages:
    - client auth
EOF

# 3. 管理员批准（真实环境里这一步要走审批流程，不能自己给自己批）
kubectl certificate approve "$user"
for _ in $(seq 10); do
  cert="$(kubectl get csr "$user" -o jsonpath='{.status.certificate}')"
  [[ -n "$cert" ]] && break
  sleep 1
done
[[ -n "${cert:-}" ]] || {
  echo "CSR 没有签发证书，检查 kubectl get csr $user" >&2
  exit 1
}
echo "$cert" | base64 -d >"$crt"

# 4. 拼 kubeconfig：集群地址和 CA 取自当前 kubeconfig
cluster="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')"
server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
ca_data="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"

ca_file="$(mktemp)"
trap 'rm -f "$ca_file"' EXIT
echo "$ca_data" | base64 -d >"$ca_file"

kubectl config --kubeconfig="$kcfg" set-cluster "$cluster" --server="$server" \
  --certificate-authority="$ca_file" --embed-certs=true >/dev/null
kubectl config --kubeconfig="$kcfg" set-credentials "$user" \
  --client-key="$key" --client-certificate="$crt" --embed-certs=true >/dev/null
kubectl config --kubeconfig="$kcfg" set-context "$user@$cluster" --cluster="$cluster" \
  --user="$user" --namespace=mall >/dev/null
kubectl config --kubeconfig="$kcfg" use-context "$user@$cluster" >/dev/null
chmod 600 "$kcfg"
rm -f "$csr"

echo "已生成 ${kcfg}（用户 ${user}，组 ${group}，有效期 ${DAYS} 天）"
echo "试一下：kubectl --kubeconfig=$kcfg auth whoami"
