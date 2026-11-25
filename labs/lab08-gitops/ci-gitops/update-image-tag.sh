#!/usr/bin/env bash
# GitOps 发布：把某个环境 values 文件里的镜像 tag 改成新版本，提交并推送到 Git。
# ArgoCD 发现 Git 变了，再去改集群。CI 不再直接碰 K8s。
#
# 在 ci-tools 镜像里运行（需要 git、yq），环境变量：
#   ENV_NAME      staging | prod
#   IMAGE_TAG     要发布的镜像 tag（短提交号或 v1.2.3）
#   GITOPS_REPO   仓库地址，不带协议，如 gitlab.lab.local/ops/ops-mall-labs.git
#   GITOPS_USER   有写权限的账号名（项目访问令牌对应的机器人用户名即可）
#   GITOPS_TOKEN  访问令牌，权限 write_repository（CI 变量里设为 Masked + Protected）
#   GITOPS_BRANCH 默认 main
set -euo pipefail

: "${ENV_NAME:?ENV_NAME 必填：staging 或 prod}"
: "${IMAGE_TAG:?IMAGE_TAG 必填}"
: "${GITOPS_REPO:?GITOPS_REPO 必填}"
: "${GITOPS_USER:?GITOPS_USER 必填}"
: "${GITOPS_TOKEN:?GITOPS_TOKEN 必填}"
GITOPS_BRANCH="${GITOPS_BRANCH:-main}"
CHART_DIR="labs/lab08-gitops/charts/ops-mall"
VALUES_FILE="${CHART_DIR}/values-${ENV_NAME}.yaml"

case "$ENV_NAME" in
  staging | prod) ;;
  *) echo "ENV_NAME 只能是 staging 或 prod" >&2; exit 1 ;;
esac
# tag 只允许字母数字和 . _ -，防止奇怪的输入被写进 YAML
if ! [[ "$IMAGE_TAG" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
  echo "IMAGE_TAG 格式不对：$IMAGE_TAG" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

git clone --quiet --depth 20 --branch "$GITOPS_BRANCH" \
  "http://${GITOPS_USER}:${GITOPS_TOKEN}@${GITOPS_REPO}" "$WORKDIR/repo"
cd "$WORKDIR/repo"
git config user.name "gitops-bot"
git config user.email "gitops-bot@lab.local"

OLD_TAG="$(yq '.api.image.tag' "$VALUES_FILE")"
if [ "$OLD_TAG" = "$IMAGE_TAG" ]; then
  echo "${ENV_NAME} 已经是 ${IMAGE_TAG}，不用改"
  exit 0
fi

# 两个镜像同一个 tag：同一次构建出来的前后端一起发
export IMAGE_TAG
yq -i '.api.image.tag = strenv(IMAGE_TAG) | .web.image.tag = strenv(IMAGE_TAG)' "$VALUES_FILE"
git --no-pager diff -- "$VALUES_FILE"

git add "$VALUES_FILE"
git commit --quiet -m "deploy(${ENV_NAME}): ops-mall ${OLD_TAG} -> ${IMAGE_TAG} [skip ci]" \
  -m "pipeline: ${CI_PIPELINE_URL:-${BUILD_URL:-manual}}"

# 几条流水线同时推送时会被拒绝，拉最新的再试
for attempt in 1 2 3; do
  # -o ci.skip：GitLab 收到这次推送不触发新流水线，避免“CI 提交触发 CI”的死循环
  if git push --quiet -o ci.skip origin "HEAD:${GITOPS_BRANCH}"; then
    echo "已推送：${ENV_NAME} -> ${IMAGE_TAG}"
    exit 0
  fi
  echo "推送失败，第 ${attempt} 次重试" >&2
  sleep $((attempt * 2))
  git pull --quiet --rebase origin "$GITOPS_BRANCH"
done
echo "推送失败，请检查令牌权限和分支保护设置" >&2
exit 1
