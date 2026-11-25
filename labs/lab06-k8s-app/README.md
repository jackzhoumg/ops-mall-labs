# Lab 06 应用上 K8s 与流量入口

对应教程：《DevOps 运维实战》Lab 06 应用上 K8s 与流量入口。实验机器：k8s-master（192.168.56.21）、k8s-node1/2（.22/.23），数据库仍在 lab-db1（192.168.56.13），都是 Ubuntu Server 24.04 LTS。集群是 Lab 05 升级后的 Kubernetes v1.37。所有 kubectl 命令在 k8s-master 上执行。

资源命名遵守 `docs/CONVENTIONS.md` 的“K8s 资源统一命名”，后续实验依赖这些名字，不要改。

## 文件

| 路径 | 用途 |
|---|---|
| `base/kustomization.yaml` | 一次性 `kubectl apply -k base` |
| `base/00-namespace.yaml` | 命名空间 `mall`（Pod 安全标准 baseline） |
| `base/10-config.yaml` | ConfigMap `mall-api-config`（非敏感环境变量） |
| `base/11-secret.yaml` | Secret `mall-api-secret`（`MALL_DB_DSN`、`MALL_REDIS_PASSWORD`，实验密码明文，真实环境别这么提交） |
| `base/20-db-endpoints.yaml` | 无选择器 Service `mysql` / `redis` + EndpointSlice `mysql-external` / `redis-external` → 192.168.56.13 |
| `base/30-api.yaml` | Deployment + Service `mall-api`（2 副本、探针、优雅退出、maxUnavailable 0） |
| `base/40-web.yaml` | Deployment + Service `mall-web`（`MALL_API_UPSTREAM`、`NGINX_RESOLVER=10.96.0.10`） |
| `base/50-pdb.yaml` | PodDisruptionBudget `mall-api` / `mall-web`（minAvailable 1） |
| `gateway/00-metallb-pool.yaml` | MetalLB 地址池 `lab-pool` 192.168.56.200-220 + L2Advertisement |
| `gateway/10-cert-issuers.yaml` | 自签根 CA → ClusterIssuer `lab-ca-issuer` |
| `gateway/11-wildcard-cert.yaml` | 通配证书 `*.lab.local` → Secret `lab-wildcard-tls`（envoy-gateway-system） |
| `gateway/20-envoyproxy.yaml` | EnvoyProxy `lab-proxy`：Envoy 的 LoadBalancer Service 固定拿 192.168.56.200 |
| `gateway/21-gatewayclass.yaml` | GatewayClass `eg` |
| `gateway/30-gateway.yaml` | Gateway `lab-gateway`（监听器 `http` / `https`，allowedRoutes All） |
| `gateway/40-httproute.yaml` | HTTPRoute `mall`（/api → mall-api，/ → mall-web）和 `mall-http-redirect`（http 301 到 https） |
| `ingress-legacy/mall-ingress.yaml` | 等价的 Ingress NGINX 写法，只做对照 |
| `faults/01..07-*.yaml` | Pod 起不来排查练习：Pending ×2、ImagePullBackOff ×2、CrashLoopBackOff、not Ready、OOMKilled |

## 写作时版本（以官方文档为准）
| 组件 | 版本 | 和 K8s 1.37 的兼容性 |
|---|---|---|
| MetalLB | v0.16.2（native 清单） | 只要求 K8s 1.13+ |
| Envoy Gateway | v1.10.0 | 兼容矩阵：K8s v1.34-v1.37，内置 Gateway API v1.6.1 |
| Gateway API | v1.6.1 标准通道（跟 Envoy Gateway 走，上游最新 v1.7.0 先不装） | 同上 |
| cert-manager | v1.21.3 | 官方支持表写到 K8s 1.36，还没列 1.37；v1.22 写作时只有 alpha，正式发布后换成它 |
| Helm | v4.3.2 | — |

## 顺序

```bash
# 0. 拉取凭据（Harbor 机器人账号，只给“拉取制品”权限）
kubectl create namespace mall --dry-run=client -o yaml | kubectl apply -f -
kubectl -n mall create secret docker-registry harbor-pull \
  --docker-server=harbor.lab.local \
  --docker-username='robot$mall+k8s-pull' \
  --docker-password='机器人密钥'

# 1. 应用
kubectl apply -k labs/lab06-k8s-app/base

# 2. MetalLB v0.16.2（native 模式，L2 够用）
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.2/config/manifests/metallb-native.yaml
kubectl -n metallb-system wait --for=condition=Available deployment/controller --timeout=5m
kubectl apply -f labs/lab06-k8s-app/gateway/00-metallb-pool.yaml

# 3. Gateway API CRD（标准通道，版本跟 Envoy Gateway 走：EG v1.10 对应 Gateway API v1.6.1）+ Envoy Gateway v1.10.0
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm --version v1.10.0 \
  --set crds.gatewayAPI.enabled=true --set crds.gatewayAPI.channel=standard \
  --set crds.envoyGateway.enabled=true | kubectl apply --server-side -f -
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.10.0 \
  -n envoy-gateway-system --create-namespace --set crds.enabled=false
kubectl -n envoy-gateway-system wait --for=condition=Available deployment/envoy-gateway --timeout=5m

# 4. cert-manager v1.21.3
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.21.3 \
  -n cert-manager --create-namespace --set crds.enabled=true
kubectl apply -f labs/lab06-k8s-app/gateway/10-cert-issuers.yaml
kubectl apply -f labs/lab06-k8s-app/gateway/11-wildcard-cert.yaml

# 5. 网关和路由
kubectl apply -f labs/lab06-k8s-app/gateway/20-envoyproxy.yaml \
              -f labs/lab06-k8s-app/gateway/21-gatewayclass.yaml \
              -f labs/lab06-k8s-app/gateway/30-gateway.yaml \
              -f labs/lab06-k8s-app/gateway/40-httproute.yaml
```

学员电脑和各虚拟机 hosts：`192.168.56.200  mall.lab.local`。根 CA 导出：
`kubectl -n cert-manager get secret lab-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > lab-root-ca.crt`

## 清理故障练习

```bash
kubectl delete -f labs/lab06-k8s-app/faults/ --ignore-not-found
```

## 验证记录
验证时间 2026-11-25。
- 已验证：全部清单用 yamlcheck 检查通过；`KUBECONFIG=/dev/null kubectl kustomize labs/lab06-k8s-app/base`（kubectl v1.37.2 / Kustomize v5.8.1，纯本地）渲染出 13 个资源，名字和 `docs/CONVENTIONS.md` 的“K8s 资源统一命名”一致；Envoy Gateway v1.10.0 的 EnvoyProxy CRD 仍是 `gateway.envoyproxy.io/v1alpha1`，`envoyService.externalTrafficPolicy` / `annotations` 字段存在；各组件版本和兼容表按官方页面核对（见上面的版本表）。
- 没有验证：所有需要集群的步骤（apply、MetalLB、Envoy Gateway、cert-manager、HTTPRoute、滚动更新、故障练习）。讲师实验机的 kubeconfig 指向生产集群，按约定不执行任何连集群的 kubectl，留给讲师在 kind 集群上统一验证。教程里的命令输出仍是示意。
- 待确认：cert-manager v1.21.3 官方支持表只到 K8s 1.36，在 1.37 上需要实测；v1.22 正式发布后建议切换。
