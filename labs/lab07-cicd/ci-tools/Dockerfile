# CI 工具镜像：kubectl + yq + git + curl，流水线的 deploy / GitOps 步骤用
# 构建并推到 Harbor（在 lab-ci 上执行，构建上下文是本目录）：
#   sudo docker build -t harbor.lab.local/library/ci-tools:v1.0.0 labs/lab07-cicd/ci-tools
#   sudo docker push harbor.lab.local/library/ci-tools:v1.0.0
# kubectl 小版本要和集群一致（课程集群 v1.36），最多差一个小版本
FROM alpine:3.24

ARG KUBECTL_VERSION=v1.36.0
ARG YQ_VERSION=v4.54.3
ARG TARGETARCH=amd64

RUN apk add --no-cache bash curl git ca-certificates jq \
 && curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && curl -fsSL -o /usr/local/bin/yq \
      "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}" \
 && chmod +x /usr/local/bin/kubectl /usr/local/bin/yq \
 && kubectl version --client \
 && yq --version

CMD ["bash"]
