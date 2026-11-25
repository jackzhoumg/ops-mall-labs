#!/usr/bin/env bash
# 安装 Velero 服务端到集群，备份存到 lab-dev 上的 SeaweedFS（桶 velero）。
# 写作时版本：Velero v1.19.0 + velero-plugin-for-aws v1.15.0（兼容表：插件 v1.15.x 对应 Velero v1.19.x），
# 以 https://velero.io/docs/ 和插件 README 的兼容表为准。
#
# 用法（k8s-master，已装好 velero 命令行、kubectl 能访问集群）：
#   cp velero/credentials-velero.example velero/credentials-velero && vi velero/credentials-velero
#   bash velero/install-velero.sh
#
# 环境变量：
#   S3_URL          默认 http://192.168.56.15:8333（lab-dev 上 SeaweedFS 的 S3 网关）
#   BUCKET          默认 velero
#   CREDS_FILE      默认 velero/credentials-velero
#   VELERO_IMAGE    默认 velero/velero:v1.19.0
#   PLUGIN_IMAGE    默认 velero/velero-plugin-for-aws:v1.15.0
#   USE_NODE_AGENT  1 = 同时部署 node-agent，用文件系统备份（Kopia）备份 PV 数据，默认 0
#
# 国内网络：Docker Hub 拉不下来时，把两个镜像同步到 Harbor，再设置 VELERO_IMAGE / PLUGIN_IMAGE，例如
#   VELERO_IMAGE=harbor.lab.local/mirror/velero:v1.19.0 PLUGIN_IMAGE=harbor.lab.local/mirror/velero-plugin-for-aws:v1.15.0
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
S3_URL="${S3_URL:-http://192.168.56.15:8333}"
BUCKET="${BUCKET:-velero}"
CREDS_FILE="${CREDS_FILE:-$here/credentials-velero}"
VELERO_IMAGE="${VELERO_IMAGE:-velero/velero:v1.19.0}"
PLUGIN_IMAGE="${PLUGIN_IMAGE:-velero/velero-plugin-for-aws:v1.15.0}"
USE_NODE_AGENT="${USE_NODE_AGENT:-0}"

command -v velero >/dev/null || { echo "没有 velero 命令行，先按教程 5.2 安装" >&2; exit 1; }
[[ -f "$CREDS_FILE" ]] || { echo "没有凭据文件 ${CREDS_FILE}，从 credentials-velero.example 复制一份并填上密钥" >&2; exit 1; }
curl -sf "$S3_URL/healthz" >/dev/null || { echo "访问不到 SeaweedFS S3 网关：$S3_URL" >&2; exit 1; }

args=(
  --provider aws
  --image "$VELERO_IMAGE"
  --plugins "$PLUGIN_IMAGE"
  --bucket "$BUCKET"
  --secret-file "$CREDS_FILE"
  # 实验集群没有支持快照的存储，不创建 VolumeSnapshotLocation
  --use-volume-snapshots=false
  # s3ForcePathStyle=true 必须加：自建 S3（SeaweedFS、MinIO、Ceph RGW）一般只支持路径风格（http://host/bucket/key），
  # 不加的话 Velero 能上传但下载失败
  --backup-location-config "region=us-east-1,s3ForcePathStyle=true,s3Url=${S3_URL}"
  --wait
)
if [[ "$USE_NODE_AGENT" == "1" ]]; then
  args+=(--use-node-agent)
fi

velero install "${args[@]}"
kubectl -n velero get pod
velero backup-location get
