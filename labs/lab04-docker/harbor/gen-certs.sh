#!/usr/bin/env bash
# 为 Harbor 生成实验用自签 CA 和服务器证书（harbor.lab.local）
#
# 用法（lab-dev 上 root 执行）：
#   ./gen-certs.sh                    # 默认输出到 /data/cert
#   CERT_DIR=/tmp/cert ./gen-certs.sh
#
# 生成：
#   ca.crt / ca.key                     实验 CA。ca.crt 要分发给所有拉镜像的机器（Docker、containerd、K8s 节点）
#   harbor.lab.local.crt / .key         Harbor 服务器证书，SAN 里包含域名和 IP
#
# ca.key 能签发任何证书，生成后妥善保管，不要提交到 Git（仓库 .gitignore 已忽略 *.key）
# 参考 Harbor 官方文档 Configure HTTPS Access to Harbor

set -Eeuo pipefail

HARBOR_DOMAIN="${HARBOR_DOMAIN:-harbor.lab.local}"
HARBOR_IP="${HARBOR_IP:-192.168.56.15}"
CERT_DIR="${CERT_DIR:-/data/cert}"
CA_DAYS="${CA_DAYS:-3650}"
# 服务器证书有效期不要超过 825 天，macOS / iOS 会拒绝更长的
CERT_DAYS="${CERT_DAYS:-825}"

log() {
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2"
}

main() {
  command -v openssl >/dev/null || { log ERROR "需要 openssl"; exit 1; }
  mkdir -p "$CERT_DIR"
  chmod 700 "$CERT_DIR"
  cd "$CERT_DIR"

  if [[ -f ca.key && -f ca.crt ]]; then
    # 重新生成 CA 会让所有已经信任旧 CA 的机器失效，默认复用
    log INFO "已存在 ca.crt，复用旧 CA"
  else
    log INFO "生成实验 CA"
    openssl genrsa -out ca.key 4096
    openssl req -x509 -new -nodes -sha512 -days "$CA_DAYS" \
      -subj "/C=CN/O=ops-mall-lab/CN=ops-mall Lab Root CA" \
      -key ca.key -out ca.crt
  fi

  log INFO "生成 ${HARBOR_DOMAIN} 服务器证书"
  openssl genrsa -out "${HARBOR_DOMAIN}.key" 4096
  openssl req -sha512 -new \
    -subj "/C=CN/O=ops-mall-lab/CN=${HARBOR_DOMAIN}" \
    -key "${HARBOR_DOMAIN}.key" -out "${HARBOR_DOMAIN}.csr"

  # 现代客户端只看 SAN（Subject Alternative Name），不看 CN。漏了 SAN 会报
  # x509: certificate relies on legacy Common Name field
  cat > v3.ext <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,nonRepudiation,keyEncipherment,dataEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${HARBOR_DOMAIN},IP:${HARBOR_IP}
EOF

  openssl x509 -req -sha512 -days "$CERT_DAYS" \
    -extfile v3.ext \
    -CA ca.crt -CAkey ca.key -CAcreateserial \
    -in "${HARBOR_DOMAIN}.csr" -out "${HARBOR_DOMAIN}.crt"

  chmod 600 ./*.key
  rm -f "${HARBOR_DOMAIN}.csr" v3.ext

  log INFO "完成，文件在 ${CERT_DIR}："
  ls -l "$CERT_DIR"
  openssl x509 -in "${HARBOR_DOMAIN}.crt" -noout -subject -enddate -ext subjectAltName
}

main "$@"
