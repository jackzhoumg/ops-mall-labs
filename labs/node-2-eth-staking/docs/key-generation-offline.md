# 离线生成验证者密钥（Hoodi 测试网）

对应教程：《Node-2 ETH 质押节点搭建与实施》5.3 节。测试网也按主网的流程做一遍，养成习惯。

## 写作时工具
| 项目 | 内容 |
|---|---|
| 工具 | ethstaker-deposit-cli v1.3.0（原 staking-deposit-cli 的社区后继版本，Lighthouse 文档和 Launchpad 都指向它） |
| 下载 | https://github.com/ethstaker/ethstaker-deposit-cli/releases |
| 文档 | https://deposit-cli.ethstaker.cc |
| 校验 | 先核对 sha256（`.sha256` 文件里只有哈希值，见下），再用 `gh attestation verify <文件名> --repo ethstaker/ethstaker-deposit-cli`，看到 `Verification succeeded!` 才继续 |

以官方文档最新版本为准。

## 1. 准备一台"离线机器"
- 最好是一台临时虚拟机或者 U 盘启动的 Live 系统，生成完密钥就销毁。
- 下载工具和校验签名在联网时做完，然后**断网**（虚拟机直接删掉网卡）再生成密钥。
- 不要在跑节点的机器、日常办公电脑上生成主网密钥。

## 2. 生成
```bash
# ops@lab-dev:~$  联网时下载并校验（写作时 v1.3.0 的文件名带提交号 d8016bc）
v=v1.3.0; f=ethstaker_deposit-cli-d8016bc-linux-amd64.tar.gz
curl -LO https://github.com/ethstaker/ethstaker-deposit-cli/releases/download/$v/$f
curl -LO https://github.com/ethstaker/ethstaker-deposit-cli/releases/download/$v/$f.sha256
echo "$(cat $f.sha256)  $f" | sha256sum -c -        # 输出 "<文件名>: OK"
gh attestation verify $f --repo ethstaker/ethstaker-deposit-cli

# ops@offline:~$  拷到离线机器、断网后执行
tar xzf ethstaker_deposit-cli-*-linux-amd64.tar.gz
cd ethstaker_deposit-cli-*-linux-amd64
./deposit new-mnemonic --chain hoodi --num_validators 1 --regular-withdrawal \
  --withdrawal_address 0x<你控制的 Hoodi 测试网地址> --folder ~/staking
```
参数说明：
- `--chain hoodi`：写错网络生成的存款数据在 Launchpad 上会被拒绝；主网是 `mainnet`。
- `--regular-withdrawal`（连字符，不是下划线）：生成 0x01 类型（最大有效余额 32 ETH）验证者，和大多数教程一致。v1.3.0 的默认值就是它，显式写上是为了不依赖默认值；要 0x02 复利型（最大有效余额 2048 ETH，可以用 `--amount` 指定存款金额）改用 `--compounding`。
- `--withdrawal_address`：取款地址，一旦上链**不能修改**，必须是你自己完全控制的地址。
- 不要把 `--keystore_password` 写在命令行上：会留在 shell 历史里。让工具交互式提示输入。

工具会显示 24 个助记词，并要求你重新输入一遍确认。

## 3. 助记词和密码怎么保管
| 东西 | 作用 | 保管方式 |
|---|---|---|
| 助记词（24 个词） | 能重新生成所有验证者密钥和取款凭证，是最高权限 | 只写在纸上 / 刻在金属板上，至少两份分开放；**永远不要拍照、不要存电脑和网盘、不要发聊天软件** |
| keystore 文件 `keystore-m_*.json` | 加密后的签名私钥，验证者客户端要用 | 拷到节点机器导入后，从节点机器删除原文件；离线介质上保留一份 |
| keystore 密码 | 解密 keystore | 密码管理器；和 keystore 分开存放 |
| `deposit_data-*.json` | 存款数据，上传到 Launchpad | 不敏感，但要核对内容 |

测试网的助记词也按这个标准管，但**绝对不要**和任何主网助记词复用。本课程所有示例里的地址和密钥都是占位符。

## 4. 拷贝到节点机器
```bash
# 用 U 盘把 ~/staking/validator_keys 拷出来，然后在 lab-eth1 上：
ls validator_keys/
# deposit_data-<时间戳>.json  keystore-m_12381_3600_0_0_0-<时间戳>.json
jq '.[0] | {pubkey, network_name, amount, withdrawal_credentials}' validator_keys/deposit_data-*.json
```
核对：`network_name` 是 `hoodi`，`withdrawal_credentials` 以 `01` 开头（0x01 类型）且后 40 位是你的取款地址。
