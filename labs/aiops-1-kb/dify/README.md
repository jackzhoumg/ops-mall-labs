# 实操 B：用 Dify 搭运维知识库（低代码）

对应教程：《AIOps-1 运维知识库与智能问答》5.5 节。

## 写作时版本与资源要求
| 项目 | 内容（以官方文档为准：https://docs.dify.ai/en/self-host/quick-start/docker-compose） |
|---|---|
| Dify | 1.20.0（2026-11-18 发布） |
| 硬件 | 至少 2 核 CPU、4 GiB 内存（官方最低要求）；实际跑知识库建议 4 核 8G |
| 软件 | Docker + Docker Compose **2.35.0 及以上**、Git、OpenSSL |
| 默认组件 | 自带 PostgreSQL、Weaviate（向量库）、Redis、Nginx、插件守护进程、沙箱等，十几个容器 |

## 部署（lab-dev 192.168.56.15）
lab-dev 上的 Harbor 已经占用 80/443，Dify 改用 8088 端口。内存只有 4G 时先停掉 Harbor（`cd ~/harbor && docker compose stop`），做完再启动。

```bash
# [ops@lab-dev ~]$
git clone --branch 1.20.0 --depth 1 https://github.com/langgenius/dify.git
cd dify/docker
cp .env.example .env
# 写作时的 .env.example 只剩必填项：COMPOSE_PROFILES（默认 weaviate,postgresql,collaboration）
# 和 agent 本地沙箱的共享令牌。令牌不填，agent 相关容器起不来
sed -i "s/^DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN=.*/DIFY_AGENT_LOCAL_SANDBOX_AUTH_TOKEN=$(openssl rand -hex 32)/" .env
# 端口改成 8088：其他默认值在 envs/ 目录里，要覆盖就追加到 .env（需要 Compose 2.35+ 才按这个优先级生效）
echo 'EXPOSE_NGINX_PORT=8088' >> .env
docker compose version          # 确认 >= 2.35.0
docker compose up -d
docker compose ps --all         # 长期运行的服务是 Up / healthy，init_permissions 是 Exited (0)
```
浏览器打开 `http://192.168.56.15:8088/install` 创建管理员账号。

国内网络：镜像在 Docker Hub（`langgenius/*`），拉不下来时参考 Lab 04 的办法：云厂商镜像仓库加速，或者境外按量服务器拉下来推到 Harbor 再改 `docker-compose.yaml` 里的 image。GitHub clone 不通时下载 release 源码包。

生产环境部署前要改掉 `.env` 里的默认密钥和数据库密码（官方文档 "Secure the Deployment" 一节）。

## 配置模型
1. 右上角头像 → 设置 → 模型供应商（Model Provider）。
2. 安装 **OpenAI-API-compatible** 插件（Dify 1.x 起模型供应商都是插件）。插件市场访问不了时，在 GitHub 的 langgenius/dify-official-plugins 下载 `.difypkg` 本地安装。
3. 添加两个模型：
   - LLM：模型名、API Key、API endpoint URL 填和 `.env.example` 里 `KB_CHAT_*` 一样的值。
   - Text Embedding：填 `KB_EMBED_*` 的值。
4. 设置 → 系统模型设置，把默认推理模型、Embedding 模型选成刚加的两个。

## 建知识库
1. 知识库 → 创建知识库 → 导入 `labs/aiops-1-kb/runbooks/` 下的 8 个 `.md` 文件（包括 `postmortems/` 里的复盘）。
2. 分段设置：选"自定义"，分段标识符填 `\n## `（按二级标题切），最大分段长度 800，重叠 100。和代码方式参数一致，方便对比。
3. 索引方式：高质量（用 Embedding 模型）。检索设置：混合检索，TopK 4，Score 阈值先关掉，观察分数后再开。
4. 等文档状态变成"可用"，在"召回测试"里输入 `eval/questions.json` 里的问题，看第一条是不是期望的文档。

## 建应用
1. 工作室 → 创建空白应用 → 聊天助手（Chatbot）。
2. 上下文：添加刚建的知识库。
3. 提示词：粘贴 `kb_core.py` 里 `SYSTEM_PROMPT` 的内容，保持和代码方式一样的规则（只根据资料回答、标注引用）。
4. 打开"引用和归属"，回答下方会显示来源片段。
5. 发布 → 访问 API → 创建 API 密钥（形如 `app-xxxx`）。

## 用 API 调用
```bash
export DIFY_BASE=http://192.168.56.15:8088/v1
export DIFY_APP_KEY=app-REPLACE_ME
bash ask_dify.sh "Redis 挂了为什么整个商城都 503"
```

## 两种方式对比（做完填自己的观察）
| 维度 | 代码方式（kb.py） | Dify |
|---|---|---|
| 搭建时间 | 读懂代码 1-2 小时 | 30 分钟（不算拉镜像） |
| 资源占用 | 一个 Python 进程 + SQLite 文件 | 十几个容器，空载 2-3G 内存 |
| 切分 / 检索可控性 | 完全可控，能加自己的规则（如关键词加权、脱敏） | 界面上能调的参数有限，定制要写插件或工作流 |
| 权限 | 自己实现 | 自带账号、工作空间、知识库权限 |
| 接入群机器人 | 自己写回调 | 有插件和 API，也要自己处理回调签名 |
| 评估 | `kb.py eval` 自动算召回率 | 召回测试靠手点，批量评估要自己调 API |
| 适合 | 想搞懂原理、要深度定制、集成进已有平台 | 快速给团队一个能用的界面、非开发人员维护知识库 |
