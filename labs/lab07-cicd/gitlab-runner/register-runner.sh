#!/usr/bin/env bash
# 注册 GitLab Runner（Docker executor）
# 在 lab-ci 上执行：
#   RUNNER_TOKEN=glrt-xxxxxxxx bash register-runner.sh
# RUNNER_TOKEN 在 GitLab 项目 > 设置 > CI/CD > Runners > 新建项目 Runner 后获得
set -euo pipefail

: "${RUNNER_TOKEN:?请先 export RUNNER_TOKEN=glrt-...}"
GITLAB_URL="${GITLAB_URL:-http://gitlab.lab.local}"
DEFAULT_IMAGE="${DEFAULT_IMAGE:-alpine:3.24}"

# --docker-volumes /var/run/docker.sock:...  让 job 里的 docker 命令直接用宿主机 Docker
#   优点：简单、构建缓存能复用；缺点：job 等于拿到宿主机 root，只能给可信项目用
# --docker-extra-hosts  job 容器里解析 GitLab 和 Harbor（实验环境没有内网 DNS）
# --docker-pull-policy if-not-present  本地有镜像就不再拉，国内网络下省很多时间
sudo docker exec gitlab-runner gitlab-runner register \
  --non-interactive \
  --url "$GITLAB_URL" \
  --token "$RUNNER_TOKEN" \
  --name "lab-ci-docker" \
  --executor docker \
  --docker-image "$DEFAULT_IMAGE" \
  --docker-volumes /var/run/docker.sock:/var/run/docker.sock \
  --docker-volumes /cache \
  --docker-extra-hosts "gitlab.lab.local:192.168.56.16" \
  --docker-extra-hosts "harbor.lab.local:192.168.56.15" \
  --docker-pull-policy if-not-present

# 同时跑的 job 数，8G 机器建议 2
sudo sed -i 's/^concurrent = .*/concurrent = 2/' /srv/gitlab-runner/config/config.toml
sudo docker restart gitlab-runner
sudo docker exec gitlab-runner gitlab-runner list
