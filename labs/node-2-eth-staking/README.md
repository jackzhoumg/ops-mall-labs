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
| MEV-Boost | v1.12（2026-02-23，镜像 `flashbots/mev-boost:1.12.0`） |
| Nethermind（课后切换执行层用） | 2.2.2（2026-10-26，镜像 `nethermind/nethermind:2.2.2`） |
| ethstaker-deposit-cli | v1.3.0（2026-04-30；v1.3.1 写作时还是预发布版） |
| Hoodi Launchpad | https://hoodi.launchpad.ethereum.org |
| 存款合约（Hoodi） | `0x00000000219ab540356cBB839Cbe05303d7705Fa` |

以官方文档最新版本为准。写作时 Hoodi 上的 Amsterdam / Gloas 升级（包含协议内置的提议者-构建者分离 ePBS）已排期又被推迟，激活后 MEV-Boost 的工作方式会变化，届时按客户端发布说明调整。

## 验证记录

验证环境同 Node-1（Ubuntu 24.04.5 systemd 容器），**没有同步链数据、没有生成真实密钥、没有存款**。

已验证：
- ethstaker-deposit-cli v1.3.0 Linux 包下载，`echo "$(cat x.sha256)  x" | sha256sum -c -` 校验 OK（`.sha256` 文件里只有哈希）。`new-mnemonic --help` 确认参数：`--num_validators`、`--withdrawal_address`、`--folder` 是下划线，**`--regular-withdrawal` 是连字符**（原来写的 `--regular_withdrawal` 会报 `No such option`，已改）；默认值就是 regular-withdrawal（0x01），`--compounding` 生成 0x02；`--chain` 可选值里有 `hoodi`、`ephemery`。
- MEV-Boost 镜像 `flashbots/mev-boost:1.12.0`：`--hoodi`、`--addr`、`--relay-check`、`--relays`、`--json` 参数都存在（compose 里的单横线写法 Go 程序同样接受）。
- Lighthouse v8.3.3：`bn --builder`、`vc --builder-proposals`、`--enable-doppelganger-protection`、`--suggested-fee-recipient`、`account validator exit` 参数都存在。
- `scripts/` 全部通过 `shellcheck` 和 `bash -n`（`source common.sh` 的 SC1091 提示用注释说明后关掉）。

没验证：
- 验证者导入、启动、存款、见证、MEV 中继注册、迁移和退出：需要同步好的 Hoodi 节点和 32 个测试币，教程里的输出是示意。
- `gh attestation verify`：Ubuntu 24.04 软件源的 gh 是 2.45.0，没有 `attestation` 子命令（2.49 起才有），教程里已提醒从 GitHub CLI 官方源安装。
