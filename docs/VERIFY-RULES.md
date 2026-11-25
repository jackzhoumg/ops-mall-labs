# 教程改写与验证的公共规则（给验证执行者看，不面向学员）

## 改写
1. 先读 `docs/CONVENTIONS.md`。操作系统只用 **Ubuntu Server 24.04 LTS**：删掉所有 Rocky / RHEL 专属操作（dnf/yum、firewalld、SELinux、nmcli、.repo、EPEL），换成 apt、ufw、AppArmor、netplan、DEB822 源。RHEL 体系只在对比或面试题里一两句带过。
2. 命令提示符改成 `ops@lab-web1:~$` / `root@lab-web1:~#`。
3. Kubernetes：Lab 05 先装 v1.36 再升到 v1.37，其余实验按 v1.37 写。所有软件版本、源地址、安装命令写之前用 web_fetch 查官方最新文档，写成“写作时版本”。
4. 笔记 frontmatter 只允许改 `status`、`stack`（技术栈变了才改）、`scene`（技术栈变了才改）。正文保持约定的 11 个二级标题，只用标准 Markdown，不出现真实公司名。
5. 预期输出：在 ops 上真跑过的，用真实输出替换（主机名、IP 按教程里的规划改写）；没跑过的保持示意，并在本实验代码目录的 `README.md` 末尾“验证记录”一节写清楚哪些已验证、哪些没验证、为什么。
6. 全部步骤都真跑通过的笔记，`status` 改成 `完成`；否则保持 `初稿`。
7. 脚本：`shellcheck` + `bash -n` 必须通过；变量后紧跟中文写成 `${var}`。YAML：`node /tmp/ohtest/yamlcheck.js <目录>`。

## 在 ops 上验证（ssh ops，Ubuntu 24.04，4C16G，有 docker 和 sudo）
- 这台机器是讲师自己的实验机，**只能新增，不能改动已有的东西**：不要在宿主机上 `apt install`、不要改宿主机的系统配置、防火墙、网络、snap、LXD。
- 所有东西都放在容器里做。已经准备好一个带 systemd 的 Ubuntu 24.04 镜像 `labv/ubuntu-systemd:24.04`（有 ops 用户、sudo 免密、sshd、ufw、cron），用法：
  ```bash
  docker run -d --name <前缀>-web1 --hostname lab-web1 --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw --network <前缀>-net --ip <IP> labv/ubuntu-systemd:24.04
  docker exec -it <前缀>-web1 bash
  ```
  容器里可以随便 apt install、改配置。
- 每个执行者只用分配给自己的**名字前缀**和**子网**：容器、网络、卷、镜像标签都以前缀开头；工作目录 `~/labverify/<前缀>/`。不要映射宿主机端口（需要时用 `docker exec` 或容器 IP 访问）。
- 往 ops 传文件用 `scp` / `rsync` 到自己的工作目录。
- 任何连接 K8s 集群的 kubectl 都**不要**执行（本机的 kubeconfig 指向生产集群）；K8s 实验的集群验证由讲师另行安排。
- 结束前**清理自己创建的全部容器、网络、卷、镜像（基础镜像 `labv/ubuntu-systemd:24.04` 除外）和工作目录**，并用 `docker ps -a --filter name=<前缀>`、`docker network ls`、`docker volume ls` 确认已清空。

## 不要做
- 不要 git commit，不要同步飞书，不要改分配范围之外的文件。
- 网络慢或下载失败时，换国内镜像重试一次；还不行就记录下来，不要长时间卡住。

## 汇报
改了哪些文件；在 ops 上真跑了哪些步骤、结果；哪些没验证、原因；清理确认结果；发现的跨实验问题。
