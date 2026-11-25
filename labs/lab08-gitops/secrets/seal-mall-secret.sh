#!/usr/bin/env bash
# 用 kubeseal 把 mall-api 的敏感配置加密成可以提交到 Git 的密文，输出一段 YAML，
# 粘贴到 values-<env>.yaml 的 api.sealedSecret 下面。
#
# 在 k8s-master（或任何装了 kubeseal、能访问集群的机器）上执行：
#   NAMESPACE=mall-staging bash labs/lab08-gitops/secrets/seal-mall-secret.sh
# 离线加密（拿不到集群权限时），先由管理员导出公钥：
#   kubeseal --fetch-cert > sealed-secrets-pub.pem
#   CERT=sealed-secrets-pub.pem NAMESPACE=mall-prod bash labs/lab08-gitops/secrets/seal-mall-secret.sh
#
# 明文只经过本机内存和管道，不落盘。
set -euo pipefail

: "${NAMESPACE:?NAMESPACE 必填：mall-staging 或 mall-prod}"
SECRET_NAME="${SECRET_NAME:-mall-api-secret}"
DB_HOST="${DB_HOST:-mysql:3306}"
CERT="${CERT:-}"

command -v kubeseal >/dev/null || { echo "没找到 kubeseal，先按教程安装" >&2; exit 1; }

read -r -p "MySQL 用户名 [mall]: " DB_USER
DB_USER="${DB_USER:-mall}"
read -r -s -p "MySQL 密码: " DB_PASS
echo
read -r -s -p "Redis 密码（没有就直接回车）: " REDIS_PASS
echo
[ -n "$DB_PASS" ] || { echo "MySQL 密码不能为空" >&2; exit 1; }

DSN="${DB_USER}:${DB_PASS}@tcp(${DB_HOST})/mall?parseTime=true&timeout=3s"

seal() {
  local args=(--raw --namespace "$NAMESPACE" --name "$SECRET_NAME" --from-file=/dev/stdin)
  if [ -n "$CERT" ]; then
    args+=(--cert "$CERT")
  fi
  printf '%s' "$1" | kubeseal "${args[@]}"
}

echo
echo "# ---- 复制到 values-${NAMESPACE#mall-}.yaml ----"
echo "api:"
echo "  sealedSecret:"
echo "    enabled: true"
echo "    encryptedData:"
echo "      MALL_DB_DSN: $(seal "$DSN")"
if [ -n "$REDIS_PASS" ]; then
  echo "      MALL_REDIS_PASSWORD: $(seal "$REDIS_PASS")"
fi
