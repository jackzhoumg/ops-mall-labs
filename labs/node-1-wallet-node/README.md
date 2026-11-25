# Node-1 区块链钱包节点运维

对应教程：《Node-1 区块链钱包节点运维》。在以太坊 Hoodi 测试网（可切换 Sepolia）上部署只读的执行层 + 共识层节点，
做好同步、RPC 对内开放与限流、高度监控与告警、多节点切换、快照备份恢复。只做技术实验，不涉及任何真实资产。

## 文件
| 路径 | 用途 |
|---|---|
| `compose.yaml` | Geth + Lighthouse 信标节点（docker compose，主线） |
| `.env.example` | 镜像版本、网络（hoodi / sepolia）、检查点同步地址、数据目录 |
| `systemd/geth.service`、`systemd/lighthouse-bn.service` | 不用 Docker 时的二进制 + systemd 方式 |
| `systemd/height-check.service` | 把 `height_check.py` 作为 exporter 常驻 |
| `height_check.py` | 多节点 / 参考节点高度对比、区块时间戳新鲜度检查；可一次性运行或作为 exporter |
| `tests/test_height_check.py` | 单元测试（unittest，不联网） |
| `nginx/rpc.conf` | JSON-RPC 对内反代：内网监听、来源白名单、API Key、限流、主备切换 |
| `monitoring/scrapeconfig.yaml` | Lab 09 的 Prometheus 抓取 Geth、Lighthouse、height-check、node_exporter |
| `monitoring/prometheusrule.yaml` | 节点挂掉、高度停滞、高度落后、最终确认停滞、对等节点少、磁盘将满 |
| `scripts/preflight.sh` | 部署前检查 CPU / 内存 / 磁盘类型和空间 / 时间同步 / 端口 |
| `scripts/gen-jwt.sh` | 生成 Engine API 的 JWT 密钥 |
| `scripts/sync-status.sh` | 查看两层的同步状态、高度、对等节点 |
| `scripts/snapshot-backup.sh`、`scripts/snapshot-restore.sh` | 停机快照备份与恢复 |
| `bitcoin/bitcoin.conf.example` | bitcoind testnet4 配置示例（对比用） |

## 机器
| 主机名 | IP | 配置 | 说明 |
|---|---|---|---|
| lab-eth1 | 192.168.56.31 | 4C16G，系统盘 + 500G SSD（Hoodi） | 本实验新增，课程环境规划里没有，按实际网段替换 |
| lab-eth2 | 192.168.56.32 | 同上 | 可选，做多节点切换时用 |

本地虚拟机磁盘和带宽不够时，用云上按量服务器（境外或香港地域同步更快），**实验完立刻释放**。

## 常用命令
```bash
cp .env.example .env && vi .env
bash scripts/preflight.sh
bash scripts/gen-jwt.sh
docker compose up -d
bash scripts/sync-status.sh
python3 height_check.py --node lab-eth1=http://127.0.0.1:8545 --reference ethpandaops=https://rpc.hoodi.ethpandaops.io
python3 -m unittest discover -s tests
```

## 写作时版本
| 组件 | 版本 |
|---|---|
| Geth | v1.17.10（2026-10-23，推迟了 Hoodi 上的 Amsterdam 升级，Hoodi 节点必须升级到这个版本） |
| Lighthouse | v8.3.3（2026-11-09） |
| Bitcoin Core | 32.1 |
| Hoodi | Chain ID 560048，2025-03-17 上线，长期支持到 2027-12，2028-12 停止（EOL） |
| Sepolia | Chain ID 11155111，应用和合约开发的默认测试网 |

以官方文档最新版本为准。
