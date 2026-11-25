# 验证者迁移检查清单（旧机器 A → 新机器 B）

对应教程：《Node-2 ETH 质押节点搭建与实施》5.7 节。

核心原则：**同一套验证者密钥，任何时刻只能在一个地方签名。** 宁可多离线 30 分钟（少拿一点奖励），也不要冒两边同时运行的风险（罚没，并被强制退出）。

## 迁移前（B 机器）
- [ ] B 的执行层和共识层已经同步完成（`bash ../node-1-wallet-node/scripts/sync-status.sh`）
- [ ] B 的时间同步正常（`timedatectl` 里 `System clock synchronized: yes`）
- [ ] B 的 compose 里 validator 服务**没有**启动（`docker ps` 里没有 lighthouse-vc）
- [ ] 准备好 keystore 文件和密码

## 停旧（A 机器）
- [ ] `bash scripts/slashing-export.sh`：停止并删除 A 的 vc 容器，导出 slashing protection 交换文件
- [ ] 禁止 A 的 vc 被再次拉起：把 A 的 `compose.yaml` 里 validator 服务的 `profiles` 改成 `["disabled-migrated"]`，或者直接删除 A 上的 `$VC_DATA_DIR/validators` 目录里的 keystore（先确认 B 上有备份）
- [ ] 如果 A 是云服务器：在控制台给 A 拍快照后**关机**，比只停容器更保险
- [ ] 记下停止时间：______

## 等待
- [ ] 至少等 2 个完整 epoch（约 13 分钟）
- [ ] 在 https://hoodi.beaconcha.in 查看验证者，确认最近的见证变成 missed（说明 A 真的不签名了）

## 起新（B 机器）
- [ ] 把交换文件拷到 B，核对 sha256 和 A 上打印的一致
- [ ] `bash scripts/import-keys.sh <validator_keys 目录>`
- [ ] `bash scripts/slashing-import.sh <交换文件>`
- [ ] `docker compose --profile validator up -d`
- [ ] 日志里看到 `Enabled validator` 和 doppelganger 检测开始；约 3 个 epoch 后看到 `Successfully published attestation`
- [ ] 浏览器上见证恢复成功；Grafana 上 `validator_monitor_prev_epoch_on_chain_attester_hit` 开始增长

## 绝对不要做
- 为了"少掉线几分钟"，在 B 启动后才去停 A
- 在 B 上加 `--init-slashing-protection` 跳过导入（会创建一个空的保护数据库，等于没有保护）
- 关掉 doppelganger 保护来加快启动
- 把同一套 keystore 同时导入两个不同的客户端（比如 Lighthouse 和 Prysm）做"高可用"。验证者的高可用只能做在信标节点和执行层上（vc 配置多个 `--beacon-nodes`），签名的 vc 只能有一个；真要做签名层高可用，用分布式验证者技术（DVT）
