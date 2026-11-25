#!/usr/bin/env bash
# 在 lab-dev 上安装单机 SeaweedFS（weed mini），作为备份专用的 S3 兼容对象存储，用 systemd 管理。
#
# 为什么不用 MinIO：MinIO 社区版 2025 年起只发源码、不再提供二进制和镜像，GitHub 仓库已归档（只读）。
# SeaweedFS 是 Apache-2.0 许可的开源项目，每周发版，官方提供 amd64 / arm64 二进制，
# 支持按账号绑定 IAM 策略、版本控制、对象锁定、生命周期，Velero 和 rclone 都能直接用。
#
# 用法（lab-dev，Ubuntu 24.04）：
#   sudo S3_ADMIN_SECRET='换成强密码' VELERO_SECRET='...' MYSQL_BACKUP_SECRET='...' bash seaweedfs/install-seaweedfs.sh
#
# 环境变量：
#   SEAWEEDFS_VERSION    默认 4.55（写作时最新版本，以 https://github.com/seaweedfs/seaweedfs/releases 为准）
#   SEAWEEDFS_TGZ        已经下载好的 linux_amd64.tar.gz / linux_arm64.tar.gz 路径（GitHub 下载慢时先在别处下好拷过来）
#   DATA_DIR             默认 /data/seaweedfs（最好是单独的磁盘）
#   S3_ADMIN_KEY         管理员 access key，默认 s3admin
#   S3_ADMIN_SECRET      必填，至少 12 位
#   VELERO_SECRET        必填，Velero 专用账号 mall-velero 的密钥
#   MYSQL_BACKUP_SECRET  必填，数据库备份专用账号 mall-mysql-backup 的密钥
#   LAB_NETWORK          防火墙只对这个网段开放 S3 端口，默认 192.168.56.0/24
set -euo pipefail
SEAWEEDFS_VERSION="${SEAWEEDFS_VERSION:-4.55}"
SEAWEEDFS_TGZ="${SEAWEEDFS_TGZ:-}"
DATA_DIR="${DATA_DIR:-/data/seaweedfs}"
S3_ADMIN_KEY="${S3_ADMIN_KEY:-s3admin}"
S3_ADMIN_SECRET="${S3_ADMIN_SECRET:-}"
VELERO_SECRET="${VELERO_SECRET:-}"
MYSQL_BACKUP_SECRET="${MYSQL_BACKUP_SECRET:-}"
LAB_NETWORK="${LAB_NETWORK:-192.168.56.0/24}"
here="$(cd "$(dirname "$0")" && pwd)"
log() { echo "$(date '+%F %T') [seaweedfs] $*"; }
die() { log "错误：$*"; exit 1; }
[[ $EUID -eq 0 ]] || die "请用 sudo 执行"
[[ ${#S3_ADMIN_SECRET} -ge 12 ]] || die "S3_ADMIN_SECRET 至少 12 位"
[[ -n "$VELERO_SECRET" && -n "$MYSQL_BACKUP_SECRET" ]] || die "VELERO_SECRET 和 MYSQL_BACKUP_SECRET 都要设置"
command -v python3 >/dev/null || die "需要 python3（Ubuntu 24.04 自带）"
# 1. 准备二进制
case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64) arch=arm64 ;;
  *) die "不支持的架构 $(uname -m)" ;;
esac
tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT
if [[ -z "$SEAWEEDFS_TGZ" ]]; then
  url="https://github.com/seaweedfs/seaweedfs/releases/download/${SEAWEEDFS_VERSION}/linux_${arch}.tar.gz"
  log "下载 ${url}"
  curl -fL --retry 3 -o "$tmpd/weed.tgz" "$url"
  curl -fsSL -o "$tmpd/weed.tgz.md5" "${url}.md5"
  # .md5 文件里只有校验值，没有文件名
  echo "$(awk '{print $1}' "$tmpd/weed.tgz.md5")  $tmpd/weed.tgz" | md5sum -c - >/dev/null || die "md5 校验失败"
  SEAWEEDFS_TGZ="$tmpd/weed.tgz"
fi
tar -xzf "$SEAWEEDFS_TGZ" -C "$tmpd" weed
install -m 755 "$tmpd/weed" /usr/local/bin/weed
/usr/local/bin/weed version
# 2. 专用用户和数据目录（最小权限：不用 root 跑）
id seaweedfs >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d "$DATA_DIR" seaweedfs
install -d -o seaweedfs -g seaweedfs -m 750 "$DATA_DIR"
# 3. S3 账号和策略（含密钥，只有 seaweedfs 用户可读）
#    mall-velero 只能读写删 velero 桶；mall-mysql-backup 只能读写 mysql-backup 桶，没有删除权限
install -d -m 750 -o root -g seaweedfs /etc/seaweedfs
umask 077
S3_ADMIN_KEY="$S3_ADMIN_KEY" S3_ADMIN_SECRET="$S3_ADMIN_SECRET" VELERO_SECRET="$VELERO_SECRET" \
MYSQL_BACKUP_SECRET="$MYSQL_BACKUP_SECRET" POLICY_DIR="$here" python3 - > /etc/seaweedfs/s3.json <<'PY'
import json, os
d = os.environ["POLICY_DIR"]
def policy(name, f):
    with open(os.path.join(d, f)) as fh:
        return {"name": name, "content": json.dumps(json.load(fh))}
def user(name, secret, **extra):
    u = {"name": name, "credentials": [{"accessKey": name, "secretKey": secret}]}
    u.update(extra)
    return u
cfg = {
    "identities": [
        {"name": "admin",
         "credentials": [{"accessKey": os.environ["S3_ADMIN_KEY"], "secretKey": os.environ["S3_ADMIN_SECRET"]}],
         "actions": ["Admin", "Read", "Write", "List", "Tagging"]},
        user("mall-velero", os.environ["VELERO_SECRET"], policyNames=["mall-velero"]),
        user("mall-mysql-backup", os.environ["MYSQL_BACKUP_SECRET"], policyNames=["mall-mysql-backup"]),
    ],
    "policies": [
        policy("mall-velero", "policy-velero.json"),
        policy("mall-mysql-backup", "policy-mysql-backup.json"),
    ],
}
print(json.dumps(cfg, indent=2))
PY
chgrp seaweedfs /etc/seaweedfs/s3.json
chmod 640 /etc/seaweedfs/s3.json
umask 022
# 4. systemd
install -m 644 "$here/seaweedfs.service" /etc/systemd/system/seaweedfs.service
systemctl daemon-reload
systemctl enable seaweedfs >/dev/null 2>&1
systemctl restart seaweedfs
# 5. 防火墙：只对实验网段开放 S3 端口 8333。
#    weed mini 同时监听 filer（8888）、master（9333）、volume（9340）等端口，这些端口不走 S3 认证，
#    绝对不能对外开放；ufw 默认拒绝入站，只放行 8333 即可
if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
  ufw allow from "$LAB_NETWORK" to any port 8333 proto tcp comment 'seaweedfs s3' >/dev/null
  log "ufw 已放行 ${LAB_NETWORK} -> 8333/tcp"
else
  log "提示：ufw 没有启用。生产环境一定要只开放 8333，filer / master / volume 端口没有认证"
fi
for _ in $(seq 1 60); do
  if curl -sf http://127.0.0.1:8333/healthz >/dev/null; then
    log "SeaweedFS 已启动：S3 API http://$(hostname -I | awk '{print $1}'):8333，桶 velero、mysql-backup 已创建"
    exit 0
  fi
  sleep 1
done
die "SeaweedFS 没有启动成功，查看：journalctl -u seaweedfs -n 50"
