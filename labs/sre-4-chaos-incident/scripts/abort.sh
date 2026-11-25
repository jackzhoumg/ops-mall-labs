#!/usr/bin/env bash
# abort.sh：紧急停止，删除命名空间里所有 Chaos Mesh 实验和定时实验，故障注入立即撤销。
# 对应教程：SRE-4 故障演练与事故管理
#
# 用法（在 k8s-master 上执行）：
#   bash abort.sh            # 默认清理 mall 命名空间
#   NS=mall bash abort.sh
#
# 原理：删除实验对象后，Chaos Mesh 控制器会通知 chaos-daemon 撤销 tc 规则、停止压力进程。
# 如果删除卡住（finalizer 不退），说明控制器和 chaos-daemon 之间通信有问题，见教程“常见的坑”。
# 注意：本脚本不处理 gameday-db-delay.sh 在数据库机器上加的延迟，那个要去 lab-db1 执行 stop。
set -euo pipefail

NS="${NS:-mall}"
kinds="schedule,workflow,podchaos,networkchaos,stresschaos,iochaos,httpchaos,timechaos,dnschaos"

echo "[$(date '+%F %T')] 紧急停止：删除命名空间 $NS 里的全部混沌实验"
kubectl -n "$NS" get "$kinds" --no-headers 2>/dev/null || true
kubectl -n "$NS" delete "$kinds" --all --wait=true --timeout=60s

left="$(kubectl -n "$NS" get "$kinds" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$left" -eq 0 ]]; then
  echo "已全部清理。接着观察 steady-state.sh 是否恢复。"
else
  echo "还有 $left 个对象没删掉，可能卡在 finalizer："
  kubectl -n "$NS" get "$kinds"
  exit 1
fi
