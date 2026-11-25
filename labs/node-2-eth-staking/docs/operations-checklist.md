# 质押节点运维检查清单

对应教程：《Node-2 ETH 质押节点搭建与实施》第 5、6 节。

## 上线前
- [ ] 机器：4 核以上 CPU、16G 以上内存（32G 更稳）、NVMe SSD；Hoodi 写作时 EL + CL 约 150-250G，预留 500G
- [ ] 时间同步：`chronyd` 运行中，偏差小于 100ms（`chronyc tracking`）
- [ ] 防火墙：P2P 端口 30303 TCP/UDP、9000 TCP/UDP、9001 UDP 对公网开放；8545、5052、5064、18550 不对公网开放
- [ ] 执行层、共识层已同步，`bash scripts/validator-status.sh` 能查到验证者
- [ ] `.env` 里 `FEE_RECIPIENT` 是自己控制的地址
- [ ] 告警已接通：`kubectl -n monitoring get prometheusrule eth-staking`，并在群里收到过一次测试告警
- [ ] 助记词纸质备份两份、keystore 离线备份一份

## 每天
- [ ] 看一眼 Grafana：见证命中率接近 100%、余额曲线向上、对等节点数稳定
- [ ] 看告警群有没有 `ValidatorMissedAttestations`

## 每周
- [ ] 磁盘增长：`df -h /data`，按增长速度估算还能撑多久
- [ ] 客户端有没有新版本：订阅 Geth、Lighthouse、MEV-Boost 的 GitHub Release；硬分叉前的版本是**必须升级**的
- [ ] 中继是否还在线：`docker compose logs mev-boost | grep -i relay | tail`

## 升级流程（以 Lighthouse 为例）
1. 读 Release Notes：有没有数据库迁移、参数变更、"必须在某时间前升级"的说明。
2. 先在另一台机器（或测试环境）用新版本跑信标节点，确认能正常同步。
3. 选时间：在浏览器查自己的验证者最近有没有轮到出块（proposer duties），避开出块前后几分钟。
4. 改 `.env` 里的 `LIGHTHOUSE_IMAGE`，然后：
   ```bash
   docker compose pull beacon validator
   docker compose up -d beacon
   docker compose logs -f beacon     # 看到 Synced 再继续
   docker compose --profile validator up -d validator
   ```
5. 升级后观察 3 个 epoch（doppelganger 期间不签名）以及之后的见证是否正常。
6. 回滚：改回旧镜像版本重新 up。注意有数据库迁移的版本可能不能直接降级，Release Notes 会写。

一次升级一个客户端，不要执行层和共识层同时升级，出问题分不清是谁。

## 掉线了怎么判断要不要急
| 情况 | 影响 | 处理 |
|---|---|---|
| 离线几分钟到几小时（单个验证者） | 只扣离线期间本该拿到的见证奖励，大致等于同样时间正常运行的收益 | 不慌，查清原因再恢复，**不要**为了抢时间在别处拉起同一密钥 |
| 全网大量验证者同时离线、链长时间不能最终确认 | 进入"不活跃惩罚"，离线的验证者扣得越来越快 | 优先恢复；关注社区公告 |
| 日志里出现 slashing protection 拦截、浏览器显示 slashed | 已经或可能被罚没 | 立刻停掉所有运行这套密钥的 vc，保留现场和日志，排查是否有重复运行 |
| 机器被入侵、keystore 可能泄露 | 别人可能用你的密钥签名导致罚没 | 停掉 vc；用离线机器生成退出消息（`exit-transaction-mnemonic`）提交自愿退出 |

## 什么时候应该主动停机
- 发现同一套密钥可能在另一处运行（迁移没按清单走、有人"帮忙"拉起了备份机器）：**马上停，停了再查**
- 硬分叉时间临近、客户端还没升级到支持的版本：升级不了就停（错误分叉上签名的风险大于离线损失）
- 系统时间严重漂移且修不好
- 磁盘快满：先停 vc 再处理，避免数据库写坏后用错误的方式重建 slashing protection

## 自愿退出（不再质押时）
1. 用 `lighthouse account validator exit --keystore <keystore 文件> --beacon-node http://127.0.0.1:5052 --network hoodi`，按提示输入确认短语。
2. 退出要排队；退出完成并经过取款延迟后，余额自动打到取款地址。
3. 退出**不可撤销**，测试网可以练一次。
