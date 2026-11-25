# Jenkins 控制器镜像：官方 LTS + docker CLI + 预装插件
# 在 lab-ci 上构建：cd labs/lab07-cicd/jenkins && sudo docker compose build
# 写作时版本：Jenkins LTS 2.580.2（JDK 21），以 jenkins.io 最新 LTS 为准

# 从官方 docker:cli 镜像里拿静态编译的 docker 客户端和 buildx 插件，省掉配 apt 源
FROM docker:29-cli AS dockercli

FROM jenkins/jenkins:2.580.2-lts-jdk21
USER root
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=dockercli /usr/local/libexec/docker/cli-plugins/docker-buildx /usr/local/libexec/docker/cli-plugins/docker-buildx
USER jenkins

# 跳过首次启动的插件安装向导里“推荐插件”那一步，插件由 plugins.txt 决定
# 国内下载插件慢时，可加 --jenkins-update-center 指向国内镜像站
COPY --chown=jenkins:jenkins plugins.txt /usr/share/jenkins/ref/plugins.txt
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
