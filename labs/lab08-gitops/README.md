# Lab 08 Helm 与 GitOps 多环境发布

对应教程：《Lab 08 Helm 与 GitOps 多环境发布》。三套环境：`mall`（Lab 07 的开发测试环境，CI 直接发布）、`mall-staging`（预发，ArgoCD 自动同步）、`mall-prod`（生产，ArgoCD 手动同步 + Argo Rollouts 金丝雀）。

## 文件

| 路径 | 用途 |
|---|---|
| `charts/ops-mall/` | ops-mall 的 Helm Chart：mall-api / mall-web 的 Deployment（生产为 Rollout）、Service、ConfigMap、Secret 引用、SealedSecret（可选）、HTTPRoute、PDB、HPA（可选）、MySQL / Redis 的无选择器 Service + EndpointSlice |
| `charts/ops-mall/values.yaml` | 默认值 |
| `charts/ops-mall/values-staging.yaml` | 预发差异：1 副本、debug 日志、`mall-staging.lab.local` |
| `charts/ops-mall/values-prod.yaml` | 生产差异：5 副本、PDB、Rollout 金丝雀、`mall-prod.lab.local` |
| `argocd/project.yaml` | AppProject：限定仓库和目标命名空间，禁止集群级资源 |
| `argocd/app-staging.yaml`、`argocd/app-prod.yaml` | 两个环境的 Application |
| `argocd/applicationset.yaml` | 用 ApplicationSet 生成上面两个 Application 的写法（二选一） |
| `argocd/argocd-cmd-params-patch.yaml` | `server.insecure=true`，由网关对外提供访问 |
| `argocd/argocd-cm-patch.yaml` | 去掉 ArgoCD 3.x 默认对 EndpointSlice 的排除，否则数据库 EndpointSlice 不会被创建 |
| `argocd/argocd-httproute.yaml` | `argocd.lab.local` 的 HTTPRoute |
| `rollouts/watch-version.sh` | 连续请求 `/api/version`，统计各版本流量比例 |
| `rollouts/gatewayapi-plugin.yaml` | 进阶：Argo Rollouts Gateway API 插件配置和 RBAC |
| `rollouts/analysis-template.example.yaml` | Lab 09 之后用：按 Prometheus 错误率自动判断金丝雀 |
| `ci-gitops/gitlab-ci-gitops.yml` | GitOps 版 GitLab CI（复制到仓库根目录替换 `.gitlab-ci.yml`） |
| `ci-gitops/update-image-tag.sh` | 用 yq 改 values 文件里的镜像 tag 并推送 |
| `ci-gitops/Jenkinsfile.gitops-stage.groovy` | Jenkins 版的 GitOps stage 片段 |
| `secrets/seal-mall-secret.sh` | 用 kubeseal 生成 mall-api-secret 的密文 |
| `secrets/mall-api-secret.example.yaml` | Secret 格式示例（占位符，不含真实密码） |

## 常用命令

```bash
# 检查
helm lint labs/lab08-gitops/charts/ops-mall
helm template ops-mall labs/lab08-gitops/charts/ops-mall -n mall-staging -f labs/lab08-gitops/charts/ops-mall/values-staging.yaml
helm template ops-mall labs/lab08-gitops/charts/ops-mall -n mall-prod -f labs/lab08-gitops/charts/ops-mall/values-prod.yaml

# 手工安装（只在 Helm 练习阶段用，交给 ArgoCD 前要 helm uninstall）
helm install ops-mall labs/lab08-gitops/charts/ops-mall -n mall-staging -f labs/lab08-gitops/charts/ops-mall/values-staging.yaml
```

## 写作时版本

| 组件 | 版本 |
|---|---|
| Helm | v4.3.x（Chart 为 apiVersion v2，Helm 3 也能用） |
| Argo CD | v3.6.2 |
| Argo Rollouts | v1.10.2 |
| Rollouts Gateway API 插件 | v0.18.0 |
| Sealed Secrets | v0.41.2 |
| yq | v4.54.3（在 ci-tools 镜像里） |

以官方文档最新版本为准。

## 和其他实验的约定

- Gateway 来自 Lab 06，按约定是 `envoy-gateway-system` 命名空间里的 `lab-gateway`；名字不同时改 `values.yaml` 的 `httpRoute.parentRefs` 和 `argocd/argocd-httproute.yaml`。Gateway 监听器必须允许 `mall-staging`、`mall-prod`、`argocd` 命名空间的路由挂载（`allowedRoutes.namespaces.from: All` 或按标签选择）。
- MySQL / Redis 仍在 lab-db1（192.168.56.13），每个命名空间各自有 `mysql`、`redis` 两个无选择器 Service。
- 镜像 `harbor.lab.local/mall/mall-api:<tag>`、`harbor.lab.local/mall/mall-web:<tag>`，tag 由 CI 写入，不用 latest。
