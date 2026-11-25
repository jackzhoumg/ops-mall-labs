# ops-mall-labs

《DevOps 运维实战》课程的实验代码仓库。一个示例商城 ops-mall 贯穿全部实验：从一台 Linux 上手工部署开始，逐步做到容器化、K8s、CI/CD、GitOps、监控和日志。

## 目录
| 目录 | 内容 |
|---|---|
| `app/` | 商城后端 mall-api（Go） |
| `web/` | 商城前端页面 |
| `sql/` | 数据库初始化脚本 |
| `docs/` | 课程统一约定、环境准备 |
| `labs/` | 每个实验的脚本和配置 |

先读 [docs/CONVENTIONS.md](docs/CONVENTIONS.md)：机器规划、域名、端口、镜像命名都在里面。

## 快速体验 mall-api
```bash
cd app
go test ./...
go run .            # 没有 MySQL 时 /healthz 返回 200，/readyz 返回 503
curl localhost:8080/healthz
```

## 使用方式
学员 fork 本仓库到自己的 Gitee / GitHub 账号，每做完一个实验提交一次。结课时这个仓库就是你的作品集。

## 版权
本仓库公开仅供浏览。课程内容版权归作者所有，未经许可不得转载或商用。
