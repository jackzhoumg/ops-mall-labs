#!/usr/bin/env bash
# etcd 快照备份：etcdctl snapshot save + etcdutl snapshot status 校验 + 清理过期文件
#
# 用法（k8s-master 上 root 执行，先用 install-etcd-tools.sh 装好 etcdctl / etcdutl）：
#   sudo ./etcd-backup.sh
#   sudo BACKUP_DIR=/data/backup/etcd KEEP_DAYS=7 ./etcd-backup.sh
# 定时任务示例（每天 02:30）：
#   30 2 * * * root /opt/ops-mall-labs/labs/lab05-k8s-cluster/etcd/etcd-backup.sh >> /var/log/etcd-backup.log 2>&1
#
# 快照里有集群全部 Secret，备份目录权限 700，传到异地时要加密
# 退出码：0 成功；1 备份或校验失败；2 参数 / 环境问题
# 对应教程：Lab 05 K8s 集群搭建与日常维护
set -Eeuo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/etcd}"
KEEP_DAYS="${KEEP_DAYS:-7}"
ENDPOINT="${ENDPOINT:-https://127.0.0.1:2379}"
PKI=/etc/kubernetes/pki/etcd
LOCK_FILE=/run/etcd-backup.lock

log() {
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2"
}

trap 'log ERROR "第 ${LINENO} 行执行失败：${BASH_COMMAND}"' ERR

check_env() {
  if (( EUID != 0 )); then
    echo "请用 root 执行（要读 ${PKI} 下的私钥）" >&2
    exit 2
  fi
  local c
  for c in etcdctl etcdutl; do
    if ! command -v "$c" >/dev/null; then
      echo "找不到 ${c}，先执行 install-etcd-tools.sh" >&2
      exit 2
    fi
  done
}

main() {
  check_env
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log WARN "上一次备份还没结束，本次跳过"
    exit 0
  fi
  install -d -m 700 "$BACKUP_DIR"
  local file
  file="${BACKUP_DIR}/etcd-$(hostname -s)-$(date +%Y%m%d-%H%M%S).db"

  # kubeadm 部署的 etcd 强制双向 TLS，用 healthcheck-client 这套客户端证书
  etcdctl --endpoints="$ENDPOINT" \
    --cacert="${PKI}/ca.crt" \
    --cert="${PKI}/healthcheck-client.crt" \
    --key="${PKI}/healthcheck-client.key" \
    snapshot save "$file"

  # snapshot status / restore 用 etcdutl：etcdctl 的同名子命令从 etcd 3.5 起废弃，官方计划在 3.6 移除
  if ! etcdutl --write-out=table snapshot status "$file"; then
    log ERROR "快照校验失败：${file}"
    exit 1
  fi
  chmod 600 "$file"
  log INFO "备份完成：${file}（$(du -h "$file" | cut -f1)）"

  find "$BACKUP_DIR" -name 'etcd-*.db' -type f -mtime +"$KEEP_DAYS" -print -delete
  log INFO "已清理 ${KEEP_DAYS} 天前的快照"
}

main "$@"
