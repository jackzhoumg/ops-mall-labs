# Lab 04 Docker 容器化与私有镜像仓库

对应教程：《DevOps 运维实战》Lab 04 Docker 容器化与私有镜像仓库。实验机器：lab-dev（192.168.56.15）。

## 文件

| 路径 | 用途 |
|---|---|
| `Dockerfile.api` | mall-api 镜像：多阶段构建、CGO_ENABLED=0、非 root、HEALTHCHECK、`--build-arg VERSION` 注入版本。默认 alpine 运行时，`--target distroless` 产出 distroless 版 |
| `Dockerfile.api.fat` | 反面教材：单阶段构建，只用来对比镜像大小 |
| `Dockerfile.web` | mall-web 镜像：nginx 官方镜像 + `web/index.html` + 反代配置模板 |
| `nginx/mall.conf.template` | mall-web 的 Nginx 配置模板，容器启动时用环境变量渲染 |
| `Dockerfile.*.dockerignore` | 每个 Dockerfile 专用的 ignore 文件（白名单），见下文 |
| `compose.yaml` | 一键启动 mysql + redis + mall-api + mall-web |
| `.env.example` | Compose 用到的密码和版本号，复制成 `.env` 使用 |
| `docker/daemon.json` | dockerd 配置示例：日志轮转、live-restore、默认网段 |
| `docker/http-proxy.conf` | dockerd 走 HTTP 代理的 systemd drop-in 示例 |
| `harbor/gen-certs.sh` | 生成实验 CA 和 `harbor.lab.local` 服务器证书（带 SAN） |
| `harbor/trust-harbor-ca.sh` | 让一台机器的系统、Docker、containerd 信任实验 CA |
| `harbor/harbor.yml.example` | Harbor 配置需要修改的项 |

## 构建上下文和 .dockerignore

约定构建上下文是**仓库根目录**（Dockerfile 里 `COPY app/`、`COPY web/index.html` 都是相对根目录的路径）。

`.dockerignore` 没有放在仓库根目录，而是用 BuildKit 的规则：和 Dockerfile 同目录、文件名为 `<Dockerfile 名>.dockerignore`，它优先于根目录的 `.dockerignore`。好处是每个镜像有自己的白名单，根目录也不用多文件。这个规则需要 BuildKit（Docker 23.0 起默认启用）。

```bash
# 在仓库根目录执行
docker build -f labs/lab04-docker/Dockerfile.api --build-arg VERSION=v1.0.0 -t harbor.lab.local/mall/mall-api:v1.0.0 .
docker build -f labs/lab04-docker/Dockerfile.api --target distroless --build-arg VERSION=v1.0.0 -t harbor.lab.local/mall/mall-api:v1.0.0-distroless .
docker build -f labs/lab04-docker/Dockerfile.web --build-arg VERSION=v1.0.0 -t harbor.lab.local/mall/mall-web:v1.0.0 .
```

## Compose

```bash
cd labs/lab04-docker
cp .env.example .env && vi .env
docker compose up -d --build
docker compose ps
curl -s http://127.0.0.1:8088/api/products | head -c 200
```

商城页面：`http://192.168.56.15:8088`（80/443 留给 Harbor）。

## Harbor

```bash
sudo ./harbor/gen-certs.sh                  # 证书到 /data/cert
# 解压离线安装包，按 harbor/harbor.yml.example 修改 harbor.yml
sudo ./install.sh --with-trivy
sudo ./harbor/trust-harbor-ca.sh /data/cert/ca.crt
docker login harbor.lab.local
docker push harbor.lab.local/mall/mall-api:v1.0.0
```

写作时 Harbor 版本 v2.16.0，从这个版本开始官方同时提供 amd64 和 arm64 离线安装包；更早的版本只有 amd64。以 Harbor GitHub Releases 页面为准。
