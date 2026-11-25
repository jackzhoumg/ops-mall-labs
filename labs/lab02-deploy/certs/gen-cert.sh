#!/usr/bin/env bash
# 生成 mall.lab.local 自签证书（带 SAN），两台 web 共用同一张
#
# 用法（lab-web1 上执行，或者在自己电脑上执行再拷过去）：
#   bash gen-cert.sh                 # 输出到当前目录
#   OUT_DIR=/tmp/certs bash gen-cert.sh
#
# 生成的文件：
#   mall.lab.local.crt   证书，拷到 /etc/nginx/ssl/，权限 644
#   mall.lab.local.key   私钥，拷到 /etc/nginx/ssl/，权限 600
#   openssl-san.cnf      openssl 配置，和 Lab 03 roles/nginx/templates/openssl-san.cnf.j2 一致
#
# 已经有证书就不覆盖（两台机器的证书要一样），想重新生成先手工删掉旧文件
# 对应教程：Lab 02 商城上线 5.12 节
set -Eeuo pipefail

DOMAIN="${DOMAIN:-mall.lab.local}"
VIP="${VIP:-192.168.56.10}"
DAYS="${DAYS:-825}"
OUT_DIR="${OUT_DIR:-.}"

CRT="${OUT_DIR}/${DOMAIN}.crt"
KEY="${OUT_DIR}/${DOMAIN}.key"
CNF="${OUT_DIR}/openssl-san.cnf"

command -v openssl >/dev/null || { echo "找不到 openssl，先 sudo apt install -y openssl" >&2; exit 1; }

mkdir -p "$OUT_DIR"

if [[ -e "$CRT" || -e "$KEY" ]]; then
  echo "${CRT} 或 ${KEY} 已存在，不覆盖。要重新生成请先删掉这两个文件" >&2
  exit 1
fi

# 现代浏览器只看 SAN（subjectAltName），不看 CN；没有 SAN 的证书 Chrome 直接报 NET::ERR_CERT_COMMON_NAME_INVALID
cat > "$CNF" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = ${DOMAIN}
[san]
subjectAltName = DNS:${DOMAIN}, IP:${VIP}
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

# 用 -config + -extensions 指定 SAN：Linux 的 OpenSSL 和 macOS 自带的 LibreSSL 都支持
# 825 天：苹果系统对服务器证书有效期的上限，超过会被 Safari 拒绝
umask 077
openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days "$DAYS" \
  -config "$CNF" -extensions san \
  -keyout "$KEY" -out "$CRT"
chmod 644 "$CRT"
chmod 600 "$KEY"

echo "证书已生成：${CRT}"
openssl x509 -in "$CRT" -noout -subject -enddate
openssl x509 -in "$CRT" -noout -text | grep -A1 'Subject Alternative Name'
