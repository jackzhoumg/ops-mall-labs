# Node-2 ETH 质押节点搭建与实施

对应教程：《Node-2 ETH 质押节点搭建与实施》。在 Hoodi 测试网搭建执行层（Geth）+ 共识层（Lighthouse）+ 验证者（Lighthouse vc）+ MEV-Boost，
完成密钥生成、导入、存款、监控，并演练防罚没的迁移流程。**只在测试网做，不涉及任何真实资产。**

## 文件
| 路径 | 用途 |
|---|---|
| `compose.yaml` | geth、beacon、mev-boost 常驻；validator 放在 `validator` profile 里，手动启用 |
| `.env.example` | 镜像版本、数据目录、手续费地址、MEV 中继（Hoodi） |
| `scripts/import-keys.sh` | 导入 keystore（vc 运行时拒绝执行） |
| `scripts/validator-status.sh` | 通过 Beacon API 查验证者索引、状态、余额 |
| `scripts/slashing-export.sh` | 停止并删除本机 vc 容器后，导出 EIP-3076 slashing protection 数据 |
| `scripts/slashing-import.sh` | 新机器导入 slashing protection 数据 |
| `scripts/common.sh` | 公共函数 |
| `monitoring/scrapeconfig.yaml` | Prometheus 抓 vc 和 bn 指标 |
| `monitoring/prometheusrule.yaml` | vc 不可用、无可用信标节点、漏见证、漏出块、余额下降、可罚没签名被拦截 |
| `docs/key-generation-offline.md` | 离线生成验证者密钥（ethstaker-deposit-cli） |
| `docs/migration-checklist.md` | 迁移验证者的逐项检查清单 |
| `docs/operations-checklist.md` | 上线、日常、升级、故障判断、自愿退出 |

执行层和共识层的 JWT、同步检查、备份脚本复用 `../node-1-wallet-node/scripts/`。

## 写作时版本
| 组件 | 版本 |
|---|---|
| Geth | v1.17.10 |
| Lighthouse（bn + vc） | v8.3.3 |
| MEV-Boost | v1.12（镜像 `flashbots/mev-boost:1.12`） |
| ethstaker-deposit-cli | v1.3.0 |
| Hoodi Launchpad | https://hoodi.launchpad.ethereum.org |
| 存款合约（Hoodi） | `0x00000000219ab540356cBB839Cbe05303d7705Fa` |

以官方文档最新版本为准。写作时 Hoodi 上的 Amsterdam / Gloas 升级（包含协议内置的提议者-构建者分离 ePBS）已排期又被推迟，激活后 MEV-Boost 的工作方式会变化，届时按客户端发布说明调整。
