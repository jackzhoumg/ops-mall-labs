# AIOps-1 运维知识库与智能问答

对应教程：《AIOps-1 运维知识库与智能问答》。用 Runbook 和故障复盘做一个能问答、回答带引用来源的运维助手。

## 文件
| 路径 | 用途 |
|---|---|
| `kb.py` | 命令行入口：`index` / `search` / `ask` / `chat` / `eval` / `stats` |
| `kb_core.py` | 纯逻辑：读 Markdown、按标题切分、余弦相似度、关键词混合打分、脱敏、拼提示词 |
| `kb_store.py` | SQLite 向量存储（向量存 BLOB，全量算余弦） |
| `kb_llm.py` | OpenAI 兼容的 Embedding / Chat 客户端，地址、密钥、模型名都从环境变量读 |
| `notify.py` | 把回答推送到企业微信"消息推送" / 钉钉自定义机器人（只发不收） |
| `bot_dingtalk.py` | 钉钉企业内部应用机器人 HTTP 回调：群里 @机器人 提问、自动回复 |
| `runbooks/` | 7 篇 ops-mall 示例 Runbook + 1 篇故障复盘（`postmortems/`） |
| `eval/questions.json` | 11 个标注了"应该命中哪篇文档"的问题，用来算召回率 |
| `tests/test_kb.py` | 单元测试，用假模型，不联网 |
| `dify/` | 实操 B：Dify 自部署和知识库应用，`ask_dify.sh` 调 Dify API |
| `.env.example` | 环境变量模板 |

## 快速开始（lab-dev 192.168.56.15 或自己电脑）
```bash
cd labs/aiops-1-kb
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt   # 国内：-i https://mirrors.aliyun.com/pypi/simple/
cp .env.example .env && vi .env    # 填模型服务地址、密钥、模型名
set -a; . ./.env; set +a
python kb.py index
python kb.py ask "Redis 挂了为什么整个商城都 503"
python kb.py eval
python -m pytest -q
```

## 写作时版本
| 组件 | 版本 |
|---|---|
| Python | 3.10 及以上（测试用 3.15） |
| openai（Python SDK） | 3.58.0 |
| Dify | 1.20.0 |

以官方文档最新版本为准。

## 安全
- `.env` 里有 API Key，已在 `.gitignore` 里，不要提交。
- 默认在发给模型之前做脱敏（`kb_core.redact`），这只是兜底；含客户数据、密钥的文档不要放进知识库。
- 公司内部资料用外部模型前要经过安全 / 合规同意；敏感场景用私有化部署的模型（见教程第 7、8 节）。
