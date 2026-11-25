#!/usr/bin/env bash
# 生成执行层和共识层之间 Engine API 用的 JWT 密钥（32 字节随机数的十六进制）。
# 两边必须读同一个文件；文件已存在就不覆盖（覆盖后要同时重启两个客户端）。
# 用法：DATA_DIR=/data/eth bash scripts/gen-jwt.sh
set -euo pipefail

DATA_DIR="${DATA_DIR:-/data/eth}"
jwt_dir="$DATA_DIR/jwt"
jwt_file="$jwt_dir/jwt.hex"

sudo mkdir -p "$jwt_dir" "$DATA_DIR/geth" "$DATA_DIR/lighthouse"
if sudo test -s "$jwt_file"; then
  echo "已存在 ${jwt_file}，不覆盖"
  exit 0
fi
openssl rand -hex 32 | tr -d '\n' | sudo tee "$jwt_file" >/dev/null
# 容器里 Geth 以 root 运行、Lighthouse 也是 root，644 可读即可；不要放进 Git、不要发到群里
sudo chmod 644 "$jwt_file"
echo "已生成 $jwt_file"
