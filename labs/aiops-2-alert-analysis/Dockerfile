# alert-analyzer 镜像。构建上下文是本目录：
#   docker build -t harbor.lab.local/ops/alert-analyzer:v1.0.0 labs/aiops-2-alert-analysis
# 国内拉 Docker Hub 慢：先把 python:3.13-slim 推到 Harbor，用 --build-arg BASE=harbor.lab.local/library/python:3.13-slim
ARG BASE=python:3.13-slim
FROM ${BASE}

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app
# 国内构建可加：--build-arg PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/
ARG PIP_INDEX_URL=https://pypi.org/simple
COPY requirements.txt .
RUN pip install --index-url "${PIP_INDEX_URL}" -r requirements.txt

COPY analyzer/ ./analyzer/

# 非 root 运行；/data 放 SQLite（分析记录和反馈）
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin analyzer \
    && mkdir -p /data && chown 10001:10001 /data
USER 10001

EXPOSE 8080
CMD ["uvicorn", "--factory", "analyzer.main:create_app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
