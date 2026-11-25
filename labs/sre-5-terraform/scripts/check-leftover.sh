#!/usr/bin/env bash
# check-leftover.sh：destroy 之后确认没有残留的收费资源。
# 对应教程：SRE-5 基础设施即代码 Terraform
#
# 用法（在执行 terraform 的机器上）：
#   bash check-leftover.sh alicloud/envs/dev
#   REGION=cn-hangzhou bash check-leftover.sh alicloud/envs/dev
#
# 做两件事：
#   1. terraform state list 必须为空（Terraform 认为自己管理的资源都已删除）
#   2. 如果装了阿里云 CLI（aliyun），再按标签 project=ops-mall-lab 查一遍 ECS，防止 state 丢了但机器还在
set -euo pipefail

dir="${1:-alicloud/envs/dev}"
REGION="${REGION:-cn-hangzhou}"
rc=0

cd "$dir"
left="$(terraform state list 2>/dev/null || true)"
if [[ -z "$left" ]]; then
  echo "[OK] $dir 的 state 里没有资源"
else
  echo "[!!] $dir 的 state 里还有资源，先 terraform destroy："
  echo "$left"
  rc=1
fi

if command -v aliyun >/dev/null; then
  count="$(aliyun ecs DescribeInstances --RegionId "$REGION" \
    --Tag.1.Key project --Tag.1.Value ops-mall-lab \
    --output cols=InstanceId,InstanceName,Status rows=Instances.Instance[] 2>/dev/null \
    | awk 'NR > 2 && NF' | tee /dev/stderr | wc -l | tr -d ' ')"
  if [[ "$count" -eq 0 ]]; then
    echo "[OK] 地域 $REGION 没有带 project=ops-mall-lab 标签的 ECS"
  else
    echo "[!!] 地域 $REGION 还有 $count 台带 project=ops-mall-lab 标签的 ECS，去控制台确认并释放"
    rc=1
  fi
else
  echo "[--] 没装 aliyun CLI，请到 ECS 控制台按标签 project=ops-mall-lab 手动确认，并查看费用中心的按量账单"
fi
exit "$rc"
