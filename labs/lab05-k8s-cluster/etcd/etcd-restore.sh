#!/usr/bin/env bash
# etcd 快照恢复（kubeadm 单控制平面、堆叠 etcd）
#
# 会让整个集群回到快照时刻：快照之后创建的 Deployment、Secret 等全部消失。只在演练或真出事时用。
#
# 用法（k8s-master 上 root 执行）：
#   sudo CONFIRM=yes ./etcd-restore.sh /var/backups/etcd/etcd-k8s-master-20261124-023000.db
#
# 流程（对应 Kubernetes 官方文档 Operating etcd clusters 的 Restoring 一节）：
#   1. 把控制平面静态 Pod 清单移走，kubelet 会停掉 apiserver / etcd 等
#   2. 旧数据目录改名留底
#   3. etcdutl snapshot restore 生成新数据目录（名字、peer 地址沿用 etcd.yaml 里的）
#   4. 清单移回，kubelet 重新拉起控制平面
# 多控制平面集群要在每台控制平面上用同一个快照恢复，并按 etcd 官方灾难恢复文档带上完整 --initial-cluster
# 对应教程：Lab 05 K8s 集群搭建与日常维护
set -Eeuo pipefail

SNAPSHOT="${1:-}"
CONFIRM="${CONFIRM:-no}"
MANIFEST_DIR=/etc/kubernetes/manifests
PARK_DIR=/etc/kubernetes/manifests-parked
DATA_DIR=/var/lib/etcd

log() {
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2"
}

trap 'log ERROR "第 ${LINENO} 行执行失败：${BASH_COMMAND}。清单在 ${PARK_DIR}，旧数据在 ${DATA_DIR}.bak-*，按教程手工回滚"' ERR

flag_value() {
  # 从 etcd.yaml 里取 --name=xxx 这类参数的值
  grep -oE -- "--$1=[^ ]+" "${PARK_DIR}/etcd.yaml" | head -1 | cut -d= -f2-
}

main() {
  if (( EUID != 0 )); then
    echo "请用 root 执行" >&2
    exit 2
  fi
  if [[ -z "$SNAPSHOT" || ! -r "$SNAPSHOT" ]]; then
    echo "用法: CONFIRM=yes $0 <快照文件>" >&2
    exit 2
  fi
  if [[ "$CONFIRM" != yes ]]; then
    echo "这会把集群回滚到快照时刻。确认要做，加 CONFIRM=yes 再执行" >&2
    exit 2
  fi
  command -v etcdutl >/dev/null || { echo "找不到 etcdutl，先执行 install-etcd-tools.sh" >&2; exit 2; }

  etcdutl --write-out=table snapshot status "$SNAPSHOT"

  log INFO "1/4 停控制平面：清单移到 ${PARK_DIR}"
  mkdir -p "$PARK_DIR"
  mv "${MANIFEST_DIR}"/*.yaml "$PARK_DIR"/
  # 等 kubelet 把 etcd 和 apiserver 容器停掉
  for _ in $(seq 1 30); do
    if ! crictl ps -q --name '^(etcd|kube-apiserver)$' | grep -q .; then break; fi
    sleep 2
  done
  if crictl ps -q --name '^(etcd|kube-apiserver)$' | grep -q .; then
    log ERROR "60 秒内 etcd / kube-apiserver 没有停掉，检查 kubelet"
    exit 1
  fi

  local name peer_url backup
  name="$(flag_value name)"
  peer_url="$(flag_value initial-advertise-peer-urls)"
  backup="${DATA_DIR}.bak-$(date +%Y%m%d-%H%M%S)"

  log INFO "2/4 旧数据目录改名为 ${backup}"
  mv "$DATA_DIR" "$backup"

  log INFO "3/4 从快照恢复到 ${DATA_DIR}（member ${name}，peer ${peer_url}）"
  etcdutl snapshot restore "$SNAPSHOT" \
    --data-dir "$DATA_DIR" \
    --name "$name" \
    --initial-cluster "${name}=${peer_url}" \
    --initial-advertise-peer-urls "$peer_url"
  chmod 700 "$DATA_DIR"

  log INFO "4/4 清单移回，等待控制平面起来"
  mv "$PARK_DIR"/*.yaml "${MANIFEST_DIR}"/
  rmdir "$PARK_DIR"
  systemctl restart kubelet
  for _ in $(seq 1 60); do
    if KUBECONFIG=/etc/kubernetes/admin.conf kubectl get --raw=/readyz >/dev/null 2>&1; then
      log INFO "apiserver 已就绪。建议再重启各节点 kubelet，并检查业务 Pod 状态"
      return 0
    fi
    sleep 5
  done
  log ERROR "5 分钟内 apiserver 没有就绪，查看 crictl ps -a 和 journalctl -u kubelet"
  exit 1
}

main "$@"
