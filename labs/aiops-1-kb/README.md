# AIOps-1 运维知识库与智能问答

对应教程：《AIOps-1 运维知识库与智能问答》。主线用开源的 **Dify** 自部署运维知识库：导入 Runbook 和故障复盘，做成回答带引用来源的值班助手，发布 API、接企业微信 / 钉钉。自写的 Python RAG 代码保留为"原理拆解（选做）"。

## 文件

| 路径 | 用途 |
|---|---|
| `runbooks/` | 7 篇 ops-mall 示例 Runbook + 1 篇故障复盘（`postmortems/`），知识库原料 |
| `eval/questions.json` | 11 个标注了"应该命中哪篇文档"的问题，用来算召回率 |
| `dify/README.md` | 主线：Dify 部署、模型、知识库、应用的操作清单 |
| `dify/import_runbooks.sh` | 用 Dify 知识库 API 批量导入 `runbooks/`，同名文档替换，可放进 CI |
| `dify/eval_recall.sh` | 用 Dify 知识库 `retrieve` 接口跑 `questions.json`，算 recall@K |
| `dify/ask_dify.sh` | 调 Dify 聊天应用 API，打印回答和引用来源 |
| `kb.py` | 原理拆解：命令行入口 `index` / `search` / `ask` / `chat` / `eval` / `stats` |
| `kb_core.py` | 原理拆解：读 Markdown、按标题切分、余弦相似度、关键词混合打分、脱敏、提示词 |
| `kb_store.py` | 原理拆解：SQLite 向量存储（向量存 BLOB，全量算余弦） |
| `kb_llm.py` | 原理拆解：OpenAI 兼容的 Embedding / Chat 客户端，配置都从环境变量读 |
| `notify.py` | 原理拆解：推送企业微信"消息推送" / 钉钉自定义机器人（只发不收） |
| `bot_dingtalk.py` | 原理拆解：钉钉企业内部应用机器人 HTTP 回调（验签、白名单、异步回复） |
| `tests/test_kb.py` | 原理拆解的单元测试，用假模型，不联网 |
| `.env.example` | 原理拆解用的环境变量模板（Dify 主线不用它） |

## 快速开始（lab-dev 192.168.56.15，Ubuntu 24.04）

```bash
# 主线：Dify（详细步骤见 dify/README.md）
git clone --branch 1.20.0 --depth 1 https://github.com/langgenius/dify.git
cd dify/docker && cp .env.example .env
sed -i "s/^DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN=.*/DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN=$(openssl rand -hex 32)/" .env
printf 'EXPOSE_NGINX_PORT=8088\nEXPOSE_NGINX_SSL_PORT=8443\n' >> .env
docker compose up -d
# 浏览器 http://192.168.56.15:8088/install → 装 OpenAI-API-compatible 插件 → 配模型 → 建空知识库 → 建知识库 API 密钥
cd ~/ops-mall-labs/labs/aiops-1-kb
export DIFY_BASE=http://192.168.56.15:8088/v1 DIFY_DATASET_ID=<知识库 ID> DIFY_DATASET_KEY=dataset-REPLACE_ME
bash dify/import_runbooks.sh
bash dify/eval_recall.sh

# 原理拆解（选做）
sudo apt install -y python3-venv
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt   # 国内：-i https://mirrors.aliyun.com/pypi/simple/
python -m pytest -q
```

## 写作时版本

| 组件 | 版本 |
|---|---|
| Dify | 1.20.0（2026-11-18） |
| Docker Compose | 2.35.0 及以上（Dify 要求） |
| Dify 插件 OpenAI-API-compatible | 0.0.87 |
| Dify 插件 企业微信 Bot / 企业微信工具 / 钉钉工具 | 0.0.10 / 0.0.12 / 0.0.11 |
| Python（原理拆解） | Ubuntu 24.04 自带 3.12 |
| openai（Python SDK） | 3.58.0 |

以官方文档最新版本为准。

## 安全

- 模型 Key 只填在 Dify 的模型供应商页面（Dify 加密存库），或原理拆解的 `.env`（已在 `.gitignore`）。`dataset-`、`app-` 密钥用环境变量传给脚本，不写进文件。
- 知识库内容会随检索结果发给模型服务。含客户数据、明文密钥的文档不要放进知识库；公司内部资料用外部模型前要经过安全 / 合规同意，敏感场景用私有化部署的模型（见教程 8.5）。
- 原理拆解代码在发给模型前做脱敏（`kb_core.redact`），这只是兜底。

## 验证记录

验证环境：讲师实验机（Ubuntu 24.04，Docker Compose v5.1.1），Dify 用官方 Compose 起在独立的 Docker 网络里（不映射宿主机端口，用容器 IP 访问）；脚本在 Ubuntu 24.04.5 systemd 容器里执行。**没有模型 Key**。

已验证：
- Dify 1.20.0 官方 Compose（`COMPOSE_PROFILES=weaviate,postgresql,collaboration` + 沙箱令牌）全部容器启动，`init_permissions` 为 `Exited (0)`；空载内存合计约 2.7G。
- `/install` 初始化管理员、登录成功；`/console/api/setup` 返回 `{"step":"finished",...}`。
- 插件市场安装 `langgenius/openai_api_compatible` 0.0.87 成功，模型供应商列表出现 `langgenius/openai_api_compatible/openai_api_compatible`。
- 不配 Embedding 模型时，高质量索引返回 `embedding model and embedding model provider are required for high quality indexing.`（写进了教程的坑）。
- 经济索引下：界面方式（控制台 API）和 `import_runbooks.sh`（知识库 API）都把 8 篇文档导入成功，状态全部 `completed`；重复执行 `import_runbooks.sh` 文档总数保持 8。召回测试"Redis 挂了 503"前 4 条都来自 `05-redis-down-site-503.md`。
- `eval_recall.sh`（`SEARCH_METHOD=keyword_search`）：recall@4 = 1.00（11/11）。
- `ask_dify.sh` 用错误密钥时输出 401 错误并返回 1。
- `shellcheck` 0.9.0 和 `bash -n`：`dify/*.sh` 全部通过。
- 原理拆解：Ubuntu 24.04 Python 3.12.3 venv 安装 `requirements.txt`（openai 3.58.0）后 `pytest` 32 个测试通过。

没验证（没有模型 Key）：
- 配置真实 LLM / Embedding 模型、高质量索引、混合检索的分数和 recall、聊天助手回答、`ask_dify.sh` 的正常回答。教程里这几处的输出是示意。
- 企业微信 Bot 插件、企业微信 / 钉钉工具插件、钉钉 Stream 模式：需要企业管理后台和公网回调地址。
- 原理拆解的 `kb.py index / ask / eval`（需要模型）。
