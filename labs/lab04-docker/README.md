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

实验机器按 Ubuntu Server 24.04 LTS 写，Docker CE 用阿里云镜像的 noble 源（DEB822 格式 `/etc/apt/sources.list.d/docker.sources`），步骤见教程 5.1。

## 验证记录

验证时间：2026-11-25，在一台 Ubuntu 24.04（4C16G，Docker 29.3.1 / Compose v5.1.1）上进行。按规定不改宿主机配置、不映射宿主机端口，镜像和容器都加了验证用前缀。

已验证：

- Docker CE 安装（在 Ubuntu 24.04 容器里）：阿里云和 download.docker.com 两个 noble 源都能 `apt update`，GPG 公钥相同；`docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin` 能装上（写作时 Docker 29.10.1、containerd 2.4.2、Compose v5.8.0、Buildx 0.39.1）；`dockerd --validate` 通过 `docker/daemon.json`，启动后日志驱动 json-file、live-restore 生效；`usermod -aG docker ops` 生效。
- 构建（构建上下文是仓库根目录）：`Dockerfile.api` 默认 alpine 版、`--target distroless`、`Dockerfile.api.fat`、`Dockerfile.web` 都构建成功。实测大小（DISK USAGE / CONTENT SIZE）：fat 1.66GB / 382MB，alpine 31.9MB / 8.69MB，distroless 22.4MB / 5.28MB，mall-web 101MB / 28.6MB。改代码后重新构建，`go mod download` 层 CACHED。
- alpine 版以 uid 10001 运行、HEALTHCHECK healthy、无数据库时 `/readyz` 503、`docker stop` 优雅退出；distroless 版 `docker exec sh` 报 executable file not found。
- `compose.yaml`（`redis:8.12-alpine`、`mysql:8.4`）：4 个服务全部 healthy，商品列表 `X-Cache: HIT`，下单 201，`down` 再 `up` 订单还在；停 Redis 后 `/readyz` 报错、mall-api 仍 healthy、商品接口 200 但耗时 3.5 秒。验证时用覆盖文件去掉了 `ports`，改从容器内访问。
- Harbor v2.16.0 amd64 离线包（md5 校验通过）：`gen-certs.sh` 生成带 SAN 的证书；`prepare --with-trivy` 后 10 个服务全部 healthy；API 建私有项目 mall（auto_scan）和机器人账号 `robot$mall+ci`；在另一台装了 Docker CE 的 Ubuntu 24.04 容器上跑 `trust-harbor-ca.sh`（系统、Docker、containerd 三处），`docker login`（单引号）、push、pull、`ctr images pull --hosts-dir` 都成功；Trivy 自动扫描完成（fat 1640 个漏洞，含 1 严重 126 高危；alpine 版 11 个，中低危）；开启“阻止高危及以上”后拉 fat 镜像返回 412，拉 alpine 版正常。

没有验证（原因）：

- Harbor 没有直接跑 `install.sh`：它会把 80/443 映射到宿主机、数据写到 `/data`，违反验证机器的限制。改成手工执行同样的步骤（`docker load`、`prepare --with-trivy`、`docker compose up -d`），并把 compose 文件里的容器名加前缀、去掉 `ports` 和 syslog 日志驱动、proxy 改为容器内监听 443。这几处改动只在验证环境，教程按官方 `install.sh` 写。
- Harbor 网页操作（建项目、机器人账号、配置拦截策略）改用了等价的 API；浏览器导入 CA 没有验证。
- `docker buildx` 多架构构建、arm64 离线包（Apple Silicon）、`registry:3` 替代方案、Harbor 代理缓存项目、`docker/http-proxy.conf`：没有对应环境，没跑。
- 宿主机发布端口（`-p 8088:80`、`127.0.0.1:8080`）没有实际映射，端口相关输出是示意。
