# 课程统一约定

所有实验教程和实验代码都遵守这份约定。改动约定时，同步检查所有实验。

## 1. 示例应用 ops-mall

| 组件 | 位置 | 说明 |
|---|---|---|
| mall-api | `app/` | Go 1.26 编写的商城后端，单个二进制，监听 `:8080` |
| mall-web | `web/index.html` | 纯静态前端页面，由 Nginx 提供，`/api/` 反向代理到 mall-api |
| 数据库脚本 | `sql/init.sql` | 建库 `mall`、账号 `mall` / `MallPass123`、表 `products` `orders`、6 条商品 |

### mall-api 接口
| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/healthz` | 存活检查，进程在就返回 200，不查依赖 |
| GET | `/readyz` | 就绪检查，MySQL（及启用时的 Redis）可用才返回 200，否则 503 |
| GET | `/api/version` | 返回 `{"version","hostname"}`，用来确认请求落到哪个实例 |
| GET | `/api/products` | 商品列表，启用 Redis 时缓存，响应头 `X-Cache: HIT/MISS` |
| GET | `/api/products/{id}` | 商品详情 |
| POST | `/api/orders` | 下单，body `{"product_id":1,"quantity":1}`，事务内扣库存，201 |
| GET | `/api/orders/{id}` | 订单详情 |
| GET | `/metrics` | Prometheus 指标 |
| GET | `/api/debug/slow?ms=2000` | 仅 `MALL_DEBUG=true`：慢请求 |
| GET | `/api/debug/error` | 仅 `MALL_DEBUG=true`：返回 500 |
| GET | `/api/debug/cpu?seconds=10` | 仅 `MALL_DEBUG=true`：占满 CPU |
| GET | `/api/debug/leak?mb=50` | 仅 `MALL_DEBUG=true`：每次多占 mb 兆内存不释放 |

所有响应带 `X-Request-ID`（透传请求头里的值，没有就生成）和 `X-Mall-Version`。

### 环境变量
| 变量 | 默认值 | 说明 |
|---|---|---|
| `MALL_LISTEN` | `:8080` | 监听地址 |
| `MALL_DB_DSN` | `mall:MallPass123@tcp(127.0.0.1:3306)/mall?parseTime=true&timeout=3s` | MySQL 连接串 |
| `MALL_REDIS_ADDR` | 空（不用缓存） | 如 `192.168.56.13:6379` |
| `MALL_REDIS_PASSWORD` | 空 | |
| `MALL_CACHE_TTL` | `30s` | 商品列表缓存时间 |
| `MALL_VERSION` | 构建时注入，默认 `dev` | |
| `MALL_DEBUG` | `false` | 开启故障演练接口 |
| `MALL_LOG_LEVEL` | `info` | |
| `MALL_SHUTDOWN_GRACE` | `10s` | 收到 SIGTERM 后的优雅退出时间 |

### 指标
`mall_http_requests_total{method,route,status}`、`mall_http_request_duration_seconds{method,route}`（直方图）、`mall_http_inflight_requests`、`mall_orders_created_total`、`mall_cache_hits_total`、`mall_cache_misses_total`、`mall_build_info{version}`，以及 Go 运行时和进程指标。`route` 是路由模板，如 `GET /api/products/{id}`。

### 日志
JSON 单行输出到标准输出（`log/slog`）。访问日志 `msg="access"`，字段：`request_id` `method` `path` `route` `status` `duration_ms` `remote_addr` `user_agent`，所有日志带 `service="mall-api"`。`/healthz` `/readyz` `/metrics` 不写访问日志。

### 构建
```bash
cd app
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w -X main.version=v1.0.0" -o mall-api .
```
国内下载依赖慢时：`go env -w GOPROXY=https://goproxy.cn,direct`。

## 2. 实验环境规划

默认用本机虚拟机，网段 `192.168.56.0/24`（VirtualBox Host-Only 默认网段；VMware、UTM、云服务器按实际网段替换，教程里提醒学员替换）。

| 主机名 | IP | 配置 | 用于 |
|---|---|---|---|
| lab-web1 | 192.168.56.11 | 1C2G | Lab 01-03：Nginx + mall-api |
| lab-web2 | 192.168.56.12 | 1C2G | Lab 02-03：Nginx + mall-api（负载均衡第二台） |
| lab-db1 | 192.168.56.13 | 2C2G | Lab 02-03：MySQL 主库 + Redis |
| lab-db2 | 192.168.56.14 | 2C2G | Lab 02：MySQL 从库 |
| — | 192.168.56.10 | — | Keepalived VIP（Lab 02） |
| lab-dev | 192.168.56.15 | 2C4G | Lab 04：Docker、Harbor |
| lab-ci | 192.168.56.16 | 4C8G | Lab 07：GitLab、Jenkins（内存不够可用云服务器按量） |
| k8s-master | 192.168.56.21 | 2C4G | Lab 05 起：控制平面 |
| k8s-node1 | 192.168.56.22 | 2C4G | 工作节点 |
| k8s-node2 | 192.168.56.23 | 2C4G | 工作节点 |

- 操作系统：**Rocky Linux 9**（与 RHEL / CentOS 体系一致，国内企业常见）。关键命令有差异时，同时给出 Ubuntu 24.04 的写法。
- 实验用户：`ops`，有 sudo 权限。命令提示符写法：`[ops@lab-web1 ~]$`（普通用户）和 `[root@lab-web1 ~]#`（root）。
- 不用的虚拟机关掉。同时开机的机器一般不超过 4 台。
- 云服务器方案：按量计费，实验完立刻释放；教程里给出释放提醒。

### 域名（写进每台机器和学员电脑的 hosts）
| 域名 | 指向 |
|---|---|
| `mall.lab.local` | Lab 02-03：VIP 192.168.56.10；Lab 06 起：K8s 网关入口 |
| `harbor.lab.local` | 192.168.56.15 |
| `gitlab.lab.local` / `jenkins.lab.local` | 192.168.56.16 |
| `argocd.lab.local` `grafana.lab.local` `prometheus.lab.local` `kibana.lab.local` | K8s 网关入口 |

## 3. 镜像与 K8s 约定
- 镜像：`harbor.lab.local/mall/mall-api:<tag>`、`harbor.lab.local/mall/mall-web:<tag>`，tag 用版本号（`v1.0.0`）或 Git 短提交号，**不用 latest**。
- Dockerfile：`labs/lab04-docker/Dockerfile.api`、`labs/lab04-docker/Dockerfile.web`，构建上下文是仓库根目录。
- K8s 命名空间：`mall`（应用）、`mall-staging` / `mall-prod`（Lab 08 多环境）、`monitoring`、`logging`、`argocd`。
- 标签：`app.kubernetes.io/name: mall-api`、`app.kubernetes.io/part-of: ops-mall`。
- Kubernetes 版本：写作时使用 **v1.36**，容器运行时 containerd，网络插件 Calico。
- 流量入口：**Gateway API + Envoy Gateway**。Ingress NGINX 已于 2026 年 3 月由 Kubernetes 官方停止维护（不再修复安全漏洞），教程里要讲清这一点：很多公司的存量集群还在用 Ingress / Ingress NGINX，要能看懂和维护，但新集群用 Gateway API。替代方案对比里列出 NGINX Gateway Fabric、Higress、Traefik、Cilium 和云厂商负载均衡。
- 入口暴露方式：裸机实验集群用 MetalLB（L2 模式）分配 `192.168.56.200-192.168.56.220`，网关拿 `192.168.56.200`；没有 MetalLB 时用 NodePort。
- 证书：cert-manager，实验用自签 CA（`lab.local` 没法申请公网证书）。
- 数据库位置：Lab 06 起 mall-api 跑在 K8s 里，**MySQL 和 Redis 仍然跑在 lab-db1（192.168.56.13）**。很多公司的数据库不上 K8s，这也让实验机器少一台。K8s 里在 `mall` 命名空间建无选择器的 Service `mysql`（3306）和 `redis`（6379），配 EndpointSlice 指向 192.168.56.13，应用用 `mysql.mall.svc:3306`、`redis.mall.svc:6379` 访问。
- Kubernetes 安装路线：Lab 05 先装 **v1.35**，再在实验里升级到 **v1.36**，让学员练一次真实的集群升级。
- Apple Silicon（M 系列）Mac：虚拟机只能跑 arm64 系统。Rocky Linux 9 有 aarch64 版本，mall-api 也能编译 arm64；但部分镜像（如 Harbor 官方镜像）只有 amd64，教程里遇到时提醒学员改用云服务器或替代方案。
- 国内网络：`registry.k8s.io`、Docker Hub、GitHub 下载经常不通。每个用到外网镜像或下载的实验，都要写“国内网络怎么办”：kubeadm 用 `--image-repository registry.aliyuncs.com/google_containers`，软件源用阿里云 / 清华镜像，Docker Hub 镜像建议用云厂商镜像仓库或境外 / 香港按量服务器中转。

## 4. 仓库目录
```
app/                   mall-api 源码
web/                   前端页面
sql/                   数据库脚本
docs/                  约定、环境准备
labs/
  basics/              入门基础包用到的脚本
  lab01-linux/         故障模拟脚本
  lab02-deploy/        Nginx / systemd / MySQL / Redis / Keepalived 配置
  lab03-automation/    Shell / Python 脚本、Ansible
  lab04-docker/        Dockerfile、Compose、Harbor
  lab05-k8s-cluster/   集群安装脚本、kubeadm 配置
  lab06-k8s-app/       K8s 清单
  lab07-cicd/          Jenkinsfile、.gitlab-ci.yml
  lab08-gitops/        Helm Chart、ArgoCD
  lab09-monitoring/    Prometheus 规则、Grafana 面板、Alertmanager
  lab10-logging/       Fluent Bit、Elasticsearch、Loki
  sre-1-tracing-slo/ … sre-6-security/
  aiops-1-kb/  aiops-2-alert-analysis/
  node-1-wallet-node/  node-2-eth-staking/
```
每个实验目录有一个 `README.md`：列出文件、用途、对应教程。

## 5. 教程写作规范（Obsidian 笔记，之后同步到飞书）
- 笔记开头的 frontmatter（`type` `track` `order` `code` `title` `scene` `level` `stack` 等）**原样保留**，课程主页依赖它。写完把 `status` 改成 `初稿`。
- 只用标准 Markdown：标题、列表、表格、代码块、引用。**不用** Obsidian 双链 `[[...]]`、callout `> [!note]`、Mermaid、HTML。架构图用代码块里的 ASCII 图。
- 正文结构固定（标题文字不改）：
  1. `## 0. 实验信息`：预计用时、前置实验、用到的机器、代码目录
  2. `## 1. 业务背景`
  3. `## 2. 本实验要点`
  4. `## 3. 企业主流方案对比`
  5. `## 4. 架构图`
  6. `## 5. 动手步骤`
  7. `## 6. 验收标准`
  8. `## 7. 常见的坑`
  9. `## 8. 原理回顾`
  10. `## 9. 面试题`
  11. `## 10. 简历写法`
- 语气：师傅带徒弟，讲人话，先做后讲原理。“为什么这么做”写在步骤旁边，一两句话。
- 每个命令代码块标明在哪台机器执行；给出关键的预期输出。
- 版本号、下载地址、仓库地址必须查过官方文档再写，写成“写作时版本”，并提醒以官方最新文档为准。
- 不出现任何真实公司名、客户名。案例写“某电商公司”“某资讯平台”。
- Web3 相关只讲技术：测试网、不谈币价和投资、不推荐交易所。
- 面试题 5-8 道，每道附“答题要点”。
- 简历写法给 1 段可直接改写的项目经历示例（背景、做了什么、结果）。
