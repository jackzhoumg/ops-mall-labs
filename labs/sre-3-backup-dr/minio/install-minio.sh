#!/usr/bin/env bash
# 在 lab-dev 上安装单机 MinIO（备份专用的 S3 兼容对象存储），用 systemd 管理。
#
# 背景：MinIO 社区版从 2025 年起只发布源码，不再提供官方编译好的二进制和镜像，
# GitHub 仓库也已标注“不再维护”。实验里从源码编译最后一个安全修复版本；
# 生产环境请评估 MinIO 商业版（AIStor）、SeaweedFS、Garage、Ceph RGW 或云厂商对象存储。
#
# 用法（lab-dev，需要 Go 1.24 及以上、4G 内存，编译约 5~10 分钟）：
#   sudo MINIO_ROOT_PASSWORD='换成强密码' bash minio/install-minio.sh
#
# 环境变量：
#   MINIO_VERSION        默认 RELEASE.2025-10-15T17-29-55Z（写作时最后一个发布的版本）
#   MINIO_ROOT_USER      默认 minioadmin
#   MINIO_ROOT_PASSWORD  必填，至少 8 位
#   MINIO_DATA_DIR       默认 /data/minio（最好是单独的磁盘）
#   MINIO_BIN            已经编译好的 minio 二进制路径（在别的机器上编译后拷过来时用），设置后跳过编译
#   GOPROXY              默认 https://goproxy.cn,direct
set -euo pipefail

MINIO_VERSION="${MINIO_VERSION:-RELEASE.2025-10-15T17-29-55Z}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-}"
MINIO_DATA_DIR="${MINIO_DATA_DIR:-/data/minio}"
MINIO_BIN="${MINIO_BIN:-}"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
here="$(cd "$(dirname "$0")" && pwd)"

log() { echo "$(date '+%F %T') [minio] $*"; }
die() { log "错误：$*"; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 sudo 执行"
[[ ${#MINIO_ROOT_PASSWORD} -ge 8 ]] || die "MINIO_ROOT_PASSWORD 至少 8 位"

# 1. 准备二进制
if [[ -n "$MINIO_BIN" ]]; then
  [[ -x "$MINIO_BIN" ]] || die "$MINIO_BIN 不存在或不可执行"
  install -m 755 "$MINIO_BIN" /usr/local/bin/minio
else
  command -v go >/dev/null || die "找不到 go。装 Go 1.24+（https://golang.google.cn/dl/）；已经装了的话用 sudo env \"PATH=\$PATH\" 执行；或者在别的机器上编译后用 MINIO_BIN 指定"
  log "从源码编译 MinIO ${MINIO_VERSION}（GOPROXY=${GOPROXY}）……"
  GOBIN=/usr/local/bin CGO_ENABLED=0 go install "github.com/minio/minio@${MINIO_VERSION}"
fi
/usr/local/bin/minio --version | head -n 1

# 2. 专用用户和数据目录（最小权限：MinIO 不用 root 跑）
id minio-user >/dev/null 2>&1 || useradd -r -s /sbin/nologin -d "$MINIO_DATA_DIR" minio-user
install -d -o minio-user -g minio-user -m 750 "$MINIO_DATA_DIR"

# 3. 配置文件（含密码，只有 root 可读）
umask 077
cat > /etc/default/minio <<EOF
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
MINIO_VOLUMES=${MINIO_DATA_DIR}
MINIO_OPTS="--address :9000 --console-address :9001"
EOF
chmod 600 /etc/default/minio
umask 022

# 4. systemd
install -m 644 "$here/minio.service" /etc/systemd/system/minio.service
systemctl daemon-reload
systemctl enable --now minio

# 5. 防火墙：9000 是 S3 API，9001 是网页控制台
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=9000/tcp --add-port=9001/tcp >/dev/null
  firewall-cmd --reload >/dev/null
fi

for _ in $(seq 1 30); do
  if curl -sf http://127.0.0.1:9000/minio/health/live >/dev/null; then
    log "MinIO 已启动：S3 API http://$(hostname -I | awk '{print $1}'):9000，控制台 :9001"
    exit 0
  fi
  sleep 1
done
die "MinIO 没有启动成功，查看：journalctl -u minio -n 50"
