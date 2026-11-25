# 主线：用 Dify 搭运维知识库

对应教程：《AIOps-1 运维知识库与智能问答》5.2-5.9 节。这里是操作清单，原因和预期输出看教程。

## 写作时版本与资源要求

| 项目 | 内容（以官方文档为准：https://docs.dify.ai/en/self-host/quick-start/docker-compose） |
|---|---|
| Dify | 1.20.0（2026-11-18 发布） |
| 硬件 | 官方最低 2 核 4G；实测空载约 2.7G 内存，建议 4 核 8G |
| 软件 | Ubuntu 24.04、Docker + Docker Compose **2.35.0 及以上**、Git、OpenSSL |
| 默认组件 | api、worker、worker_beat、api_websocket、web、nginx、PostgreSQL、Weaviate、Redis、plugin_daemon、sandbox、agent_backend、local_sandbox、两个 squid 代理 |

## 1. 部署（lab-dev 192.168.56.15）

lab-dev 上的 Harbor 已经占用 80/443，Dify 改用 8088 / 8443。内存不够时先停 Harbor（`cd ~/harbor && docker compose stop`），做完再启动。

```bash
# ops@lab-dev:~$
git clone --branch 1.20.0 --depth 1 https://github.com/langgenius/dify.git
cd dify/docker
cp .env.example .env
# .env.example 只有两项必填：COMPOSE_PROFILES（默认 weaviate,postgresql,collaboration）和 agent 沙箱令牌
sed -i "s/^DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN=.*/DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN=$(openssl rand -hex 32)/" .env
# 其他默认值在 envs/ 目录，要覆盖就追加到 .env（Compose 2.35+ 才按这个优先级生效）
printf 'EXPOSE_NGINX_PORT=8088\nEXPOSE_NGINX_SSL_PORT=8443\n' >> .env
docker compose version          # 确认 >= 2.35.0
docker compose up -d
docker compose ps --all         # 长期运行的服务是 Up / healthy，init_permissions 是 Exited (0)
```

浏览器打开 `http://192.168.56.15:8088/install` 创建管理员账号。**谁先打开谁就是管理员**，部署完马上做。

国内网络：镜像在 Docker Hub（`langgenius/*` 等）和 `cr.weaviate.io`，拉不下来时参考 Lab 04：云厂商镜像仓库加速，或者境外按量服务器拉下来推到 Harbor 再覆盖镜像地址。GitHub clone 不通时下载 Release 源码包。

生产环境部署前要改掉默认密钥和数据库密码（官方文档 "Secure the Deployment" 一节），加 HTTPS。

## 2. 配置模型

1. 右上角头像 → 设置 → 模型供应商。
2. 安装 **OpenAI-API-compatible** 插件（`langgenius/openai_api_compatible`）。插件市场访问不了时，下载 `.difypkg` 本地安装。
3. 添加两个模型（占位符换成你的值）：
   - LLM：模型名 `your-chat-model`，API Key `sk-REPLACE_ME`，API endpoint URL `https://llm.example.com/v1`。
   - Text Embedding：模型名 `your-embedding-model`，同上。
4. 设置 → 系统模型设置，把系统推理模型、Embedding 模型选成刚加的两个。

## 3. 建知识库、导入 Runbook

界面方式：知识库 → 创建知识库 → 导入 `runbooks/` 下的 8 个 `.md` 文件（包括 `postmortems/`）。

| 设置 | 值 |
|---|---|
| 分段模式 | 通用（自定义） |
| 分段标识符 | `\n## ` |
| 分段最大长度 / 重叠 | 800 / 100 |
| 预处理 | 替换连续空格；不删除 URL 和邮箱 |
| 索引方式 | 高质量（必须先配好 Embedding 模型） |
| 检索设置 | 混合检索，TopK 4，Score 阈值先关 |

API 方式（推荐，可放进 Runbook 仓库的 CI）：先建一个空知识库，在知识库的"API"页面创建 `dataset-` 开头的密钥。

```bash
cd ~/ops-mall-labs/labs/aiops-1-kb
export DIFY_BASE=http://192.168.56.15:8088/v1 DIFY_DATASET_ID=<知识库 ID>
read -rsp 'dataset key: ' DIFY_DATASET_KEY && export DIFY_DATASET_KEY && echo
bash dify/import_runbooks.sh                 # 没有 Embedding 模型时：DIFY_INDEXING=economy bash dify/import_runbooks.sh
bash dify/eval_recall.sh                     # 经济索引用 SEARCH_METHOD=keyword_search
```

## 4. 建应用、发布 API

1. 工作室 → 创建空白应用 → 聊天助手。
2. 上下文：添加刚建的知识库，召回设置和上面一致。
3. 指令：粘贴教程 5.8 的提示词（和 `kb_core.py` 的 `SYSTEM_PROMPT` 一致）。
4. 打开"引用和归属"；温度 0.1-0.3。
5. 发布 → 访问 API → 创建 API 密钥（`app-` 开头）。

```bash
export DIFY_BASE=http://192.168.56.15:8088/v1
read -rsp 'app key: ' DIFY_APP_KEY && export DIFY_APP_KEY && echo
bash dify/ask_dify.sh "Redis 挂了为什么整个商城都 503"
```

## 5. 接企业微信 / 钉钉

| 需求 | 做法 |
|---|---|
| 企业微信群里 @机器人 提问 | 插件"企业微信 Bot"（`langgenius/wecom-bot`）：企业微信后台建智能机器人（API 模式）拿 Token、EncodingAESKey → Dify 里添加端点配置并选应用 → 把生成的回调 URL 填回企业微信。回调 URL（`/e/` 开头）要能被企业微信访问 |
| 把回答 / 通知推到群里（只发不收） | 工作流里用工具插件"企业微信"（`langgenius/wecom`）或"钉钉"（`langgenius/dingtalk`）节点，填群机器人 Webhook；或者调用方自己推 |
| 钉钉群里 @机器人 提问 | 钉钉企业内部应用机器人，推荐 Stream 模式；收到消息后调 Dify `/v1/chat-messages`。`../bot_dingtalk.py` 演示了 HTTP 回调模式下的验签和白名单 |

## 两种方式对比（做完填自己的观察）

| 维度 | Dify（主线） | 自写代码（原理拆解） |
|---|---|---|
| 搭建时间 | 30-60 分钟（不算拉镜像） | 读懂代码 1-2 小时 |
| 资源占用 | 十几个容器，空载约 2.7G 内存 | 一个 Python 进程 + SQLite 文件 |
| 切分 / 检索可控性 | 界面上能调的参数有限，定制要写插件或工作流 | 完全可控，能加自己的规则（关键词加权、脱敏） |
| 权限 | 自带账号、工作空间、知识库权限 | 自己实现 |
| 接入群机器人 | 有企业微信 Bot 插件和群消息工具 | 自己写回调 |
| 评估 | 召回测试手点；`eval_recall.sh` 批量算 | `kb.py eval` |
| 适合 | 快速给团队一个能用的助手、非开发人员维护知识库 | 搞懂原理、要深度定制、集成进已有平台 |
