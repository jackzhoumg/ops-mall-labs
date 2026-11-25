# Lab 07 CI/CD 自动化流水线

对应教程：《Lab 07 CI/CD 自动化流水线》。所有服务跑在 lab-ci（192.168.56.16，4C8G），发布目标是 K8s 的 `mall` 命名空间。

## 文件

| 文件 | 用途 | 在哪执行 |
|---|---|---|
| `.gitlab-ci.yml` | GitLab CI 流水线：test → build → scan → push → deploy。**使用时复制到仓库根目录**：`cp labs/lab07-cicd/.gitlab-ci.yml .gitlab-ci.yml` | GitLab Runner |
| `Jenkinsfile` | Jenkins 声明式流水线，功能与 `.gitlab-ci.yml` 相同。多分支流水线的 Script Path 填 `labs/lab07-cicd/Jenkinsfile` | Jenkins |
| `gitlab/docker-compose.yml` | GitLab CE（已按 8G 内存做了精简配置） | lab-ci |
| `gitlab-runner/docker-compose.yml` | GitLab Runner 容器 | lab-ci |
| `gitlab-runner/register-runner.sh` | 用 `glrt-` 开头的 Runner Token 注册 Docker executor | lab-ci |
| `jenkins/Dockerfile`、`jenkins/plugins.txt`、`jenkins/docker-compose.yml` | Jenkins LTS + docker CLI + 预装插件 | lab-ci |
| `ci-tools/Dockerfile` | 流水线工具镜像（kubectl、yq、git），推到 `harbor.lab.local/library/ci-tools:v1.0.0` | lab-ci |
| `k8s/ci-deployer-rbac.yaml` | CI 发布账号：`mall` 命名空间内只能 get/patch Deployment | k8s-master |
| `k8s/make-kubeconfig.sh` | 生成 ci-deployer 专用 kubeconfig | k8s-master |

## 写作时版本

| 组件 | 版本 |
|---|---|
| GitLab CE | 19.6.1-ce.0 |
| GitLab Runner | v19.6.0 |
| Jenkins LTS | 2.580.2（`jenkins/jenkins:2.580.2-lts-jdk21`） |
| Trivy | 0.76.2 |
| docker CLI 镜像 | `docker:29-cli` |

以官方文档最新版本为准。

## 需要的 CI/CD 变量（GitLab）/ 凭据（Jenkins）

| GitLab 变量 | Jenkins 凭据 ID | 内容 | 设置 |
|---|---|---|---|
| `HARBOR_USER` | `harbor-robot`（用户名） | Harbor 机器人账号，如 `robot$mall+ci` | Protected，取消 Expand variable reference |
| `HARBOR_PASSWORD` | `harbor-robot`（密码） | 机器人账号密钥 | Masked + Protected |
| `KUBECONFIG_MALL` | `kubeconfig-mall`（Secret file） | `make-kubeconfig.sh` 的输出 | 类型 File，Protected |

## 和其他实验的约定

- Dockerfile 用 `labs/lab04-docker/Dockerfile.api`、`Dockerfile.web`，构建上下文是仓库根目录；版本号通过 `--build-arg VERSION=<tag>` 传入（以 Lab 04 Dockerfile 实际的 ARG 名为准）。
- `kubectl set image` 假设 Lab 06 的 Deployment 叫 `mall-api` / `mall-web`，容器名同名。
- 镜像 tag：分支构建用 8 位短提交号，`v1.2.3` 标签构建用标签名，不用 latest。
