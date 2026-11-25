# SRE-6 集群安全加固

对应教程：《DevOps 运维实战》进阶 SRE-6 集群安全加固

写作时版本：Trivy 0.76.2，kube-bench 0.16.0（CIS Kubernetes Benchmark cis-2.0），Falco 0.45.2（Helm Chart 9.2.2），cosign 3.1.4。以官方最新文档为准。

前提：Lab 04 的 Harbor、Lab 05-06 的集群和 mall 应用、Lab 07 的流水线、Lab 09 的监控已经可用。kubectl 命令默认在 k8s-master 上执行。

## 文件

| 路径 | 用途 | 教程章节 |
|---|---|---|
| `trivy/scan-image.sh` | 扫描镜像，有可修复的高危漏洞时非 0 退出 | 5.1 |
| `trivy/.trivyignore.example` | 漏洞豁免文件示例（带到期时间） | 5.1 |
| `trivy/gitlab-ci-trivy.yml` | GitLab CI 镜像扫描 job | 5.1 |
| `trivy/Jenkinsfile.scan-stage` | Jenkins 镜像扫描 stage | 5.1 |
| `kube-bench/job-master.yaml` | 控制平面 CIS 基线检查 Job | 5.2 |
| `kube-bench/job-node.yaml` | 工作节点 CIS 基线检查 Job | 5.2 |
| `kube-bench/audit-policy.yaml` | API Server 审计策略 | 5.2 |
| `rbac/01-developer.yaml` | 开发角色（mall 命名空间，组 mall-dev） | 5.3 |
| `rbac/02-ops-readonly.yaml` | 只读运维（全集群只读，组 ops-readonly） | 5.3 |
| `rbac/03-ci-deployer.yaml` | CI 部署账号（ServiceAccount，只能更新指定 Deployment） | 5.3 |
| `rbac/create-user-kubeconfig.sh` | 用 CSR API 签发用户证书并生成 kubeconfig | 5.3 |
| `rbac/verify-rbac.sh` | 用 kubectl auth can-i 批量验证权限 | 5.3 |
| `pod-security/namespace-mall-psa.yaml` | mall 命名空间 Pod Security 标签 | 5.4 |
| `pod-security/mall-api-hardening-patch.yaml` | mall-api securityContext 加固补丁 | 5.4 |
| `pod-security/mall-web-nonroot/` | mall-web 非 root 镜像（Dockerfile、Nginx 配置、Deployment 补丁） | 5.4 |
| `pod-security/test-bad-pod.yaml` | 违规 Pod，用来验证 restricted 会拒绝 | 5.4 |
| `networkpolicy/00-05-*.yaml` | 默认拒绝 + 逐条放行 | 5.5 |
| `networkpolicy/test-netpol.sh` | 验证该通的通、该断的断 | 5.5 |
| `falco/values-falco.yaml` | Falco Helm values（modern_ebpf、JSON 输出） | 5.6 |
| `falco/mall-rules.yaml` | 自定义规则：mall 容器里起 shell、mall-api 异常进程、包管理器 | 5.6 |
| `falco/trigger-test.sh` | 触发告警并查看 | 5.6 |

## 建议顺序

镜像扫描 → kube-bench → RBAC → Pod Security → NetworkPolicy → Falco。
NetworkPolicy 的 `00-default-deny.yaml` 一 apply 商城就断，要紧接着 apply 01-05。

## 回滚

```bash
kubectl delete -f networkpolicy/                                        # 去掉全部网络策略
kubectl label ns mall pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl -n mall rollout undo deployment/mall-api                        # 撤销加固补丁
helm uninstall falco -n falco
kubectl delete ns kube-bench
```
