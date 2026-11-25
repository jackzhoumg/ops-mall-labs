# Lab 05 K8s 集群搭建与日常维护
对应教程：《DevOps 运维实战》Lab 05 K8s 集群搭建与日常维护。

用 kubeadm 在 Ubuntu Server 24.04 LTS 上搭一套 1 master + 2 worker 的集群（containerd 2.x + Calico），先装 v1.36，再按官方流程升级到 v1.37；练节点维护、证书续期、etcd 备份恢复。

## 机器
| 主机名 | IP | 配置 |
|---|---|---|
| k8s-master | 192.168.56.21 | 2C4G，Ubuntu Server 24.04 LTS |
| k8s-node1 | 192.168.56.22 | 2C4G |
| k8s-node2 | 192.168.56.23 | 2C4G（实验里后加入，练扩容） |

另外要用到 Lab 04 的 Harbor（lab-dev 192.168.56.15）。

## 文件
| 路径 | 用途 | 在哪执行 |
|---|---|---|
| `prepare-node.sh` | 主机名、hosts、关 swap（含 fstab 里的 `/swap.img`）、overlay / br_netfilter、sysctl、chrony、AppArmor 检查、ufw（`FIREWALL_MODE=disable/open`）、kubelet `--node-ip` | 每台节点 |
| `install-containerd.sh` | 配 Docker 官方 apt 源（DEB822 `docker.sources`，默认阿里云镜像），装 containerd.io 2.x，生成 config.toml，改 SystemdCgroup / sandbox / config_path，写 Harbor hosts.toml | 每台节点 |
| `containerd/config-k8s.toml` | containerd 2.x 里 K8s 要改的三处配置，手工改时对照 | — |
| `containerd/certs.d/harbor.lab.local/hosts.toml` | Harbor 自签证书配置 | 复制到 `/etc/containerd/certs.d/harbor.lab.local/` |
| `containerd/certs.d/docker.io/hosts.toml.example` | Docker Hub 加速模板 | 按需 |
| `install-kube.sh` | 配 pkgs.k8s.io / 阿里云 kubernetes-new 的 deb 源（DEB822 `kubernetes.sources`），装 kubeadm、kubelet、kubectl、cri-tools，`apt-mark hold` 锁版本；`REPO_ONLY=true` 只换源 | 每台节点 |
| `kubeadm-config.yaml` | `kubeadm init` 配置：版本、controlPlaneEndpoint、podSubnet、国内镜像仓库 | k8s-master |
| `calico/custom-resources.yaml` | Calico（Tigera Operator）安装参数，Pod 网段 10.244.0.0/16 | k8s-master |
| `etcd/install-etcd-tools.sh` | 装和集群同版本的 etcdctl / etcdutl | k8s-master |
| `etcd/etcd-backup.sh` | etcd 快照备份 + 校验 + 清理 | k8s-master（可放 cron） |
| `etcd/etcd-restore.sh` | etcd 快照恢复（需 `CONFIRM=yes`） | k8s-master |
| `upgrade/upgrade-control-plane.sh` | 控制平面 v1.36 → v1.37，每步停下确认 | k8s-master |
| `upgrade/upgrade-node.sh` | 工作节点升级，drain / uncordon 提示到 master 上执行 | 每台工作节点 |
| `test/demo-app.yaml` | 从 Harbor 拉 mall-api 跑 3 副本 + PDB，验证网络、证书和 drain | k8s-master |

## 快速使用
```bash
# 每台节点（主机名和 IP 按本机改）
sudo NODE_NAME=k8s-master NODE_IP=192.168.56.21 ./prepare-node.sh
scp ops@192.168.56.15:/data/cert/ca.crt /tmp/harbor-ca.crt
sudo HARBOR_CA=/tmp/harbor-ca.crt ./install-containerd.sh
sudo ./install-kube.sh                      # 默认 v1.36、阿里云镜像

# k8s-master
sudo kubeadm init --config kubeadm-config.yaml --upload-certs
mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown "$(id -u):$(id -g)" ~/.kube/config
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.33.1/manifests/v3_projectcalico_org.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.33.1/manifests/tigera-operator.yaml
kubectl create -f calico/custom-resources.yaml

# 工作节点：用 init 输出的 kubeadm join 命令

# 升级到 v1.37（先 etcd/etcd-backup.sh）
sudo ./upgrade/upgrade-control-plane.sh 1.37.2   # k8s-master
sudo ./upgrade/upgrade-node.sh 1.37.2            # 每台工作节点，一次一台
```

## 写作时版本（以官方最新文档为准）
| 组件 | 版本 | 来源 |
|---|---|---|
| Kubernetes | v1.36.6 → v1.37.2 | pkgs.k8s.io / mirrors.aliyun.com/kubernetes-new（deb 包版本号 `1.36.6-1.1`） |
| containerd | 2.4.2（containerd.io `2.4.2-4~ubuntu.24.04~noble`，`config default` 生成 `version = 4`） | download.docker.com/linux/ubuntu（noble） |
| Calico | v3.33.1（Tigera Operator，官方测试 K8s 1.35 / 1.36 / 1.37） | docs.tigera.io |
| etcd | 3.6.8（v1.36）→ 3.7.0（v1.37） | kubeadm 源码 constants.go |
| pause | 3.10.2（v1.36、v1.37 相同） | kubeadm 源码 constants.go |
| CoreDNS | v1.14.2（v1.36）→ v1.14.6（v1.37） | kubeadm 源码 constants.go |
| kubeadm 配置 API | `kubeadm.k8s.io/v1beta4`（v1.37 新增了 `kubeadm.k8s.io/v1`，v1beta4 仍是优先版本） | kubeadm 源码 apis/kubeadm |

## 注意
- 脚本都可以重复执行；`etcd-restore.sh` 会让集群回到快照时刻，只在演练时用。
- Calico 写作时对 K8s 1.34/1.35 和 1.36+ 提供两份 CRD 清单（`v3_projectcalico_org-v1beta1.yaml` 和 `v3_projectcalico_org.yaml`）。本实验从 1.36 起步，直接用不带后缀的那份，升级到 1.37 不用换。
- `/etc/default/kubelet` 是 kubelet 包的配置文件。`prepare-node.sh` 先写了它，所以 `install-kube.sh` 和升级脚本装包时都带 `-o Dpkg::Options::=--force-confold`，否则 dpkg 会停下来问要不要覆盖。
- 新版 kubeadm 包不再依赖 cri-tools，`install-kube.sh` 单独装它，`crictl` 才有。

## 验证记录
验证时间 2026-11-25。环境：讲师实验机上的 `labv/ubuntu-systemd:24.04` 容器（Ubuntu 24.04.5 LTS，带 systemd，`--privileged`，内存限制 1G），容器 IP 172.30.5.21，用 `LAB_NET=172.30.5` 代替 192.168.56。没有真集群，**没有执行 `kubeadm init`**。

已真跑通过：
- `prepare-node.sh`：默认 `FIREWALL_MODE=disable` 和 `open` 两种都跑过，重复执行 4 次 hosts 条目不重复；fstab 里的 `/swap.img` 被注释；`modules-load.d`、`sysctl.d` 文件写入正确；chrony 装好后 systemd-timesyncd 被替换；ufw open 模式的 `ufw status verbose` 输出已写进教程。
- `install-containerd.sh`：从阿里云 Docker CE 镜像装上 `containerd.io 2.4.2-4~ubuntu.24.04~noble`；`config default` 生成 `version = 4`；SystemdCgroup、sandbox、config_path 三处改成功，`crictl info` 里 `SystemdCgroup: true`；带 `HARBOR_CA`（用临时自签 CA 代替 Harbor CA）时 `ca.crt` 和 `hosts.toml` 都写到 `/etc/containerd/certs.d/harbor.lab.local/`；`ctr` 从阿里云拉 `pause:3.10.2` 成功。
- `install-kube.sh`：阿里云 `kubernetes-new` v1.36 源装上 kubeadm / kubelet / kubectl 1.36.6-1.1、cri-tools 1.36.0，三个包 hold；`REPO_ONLY=true KUBE_MINOR=v1.37` 换源后 `apt-cache madison` 能看到 1.37.0 / 1.37.1 / 1.37.2，`apt-get -s upgrade` 显示三个包 kept back；`KUBE_REPO=official` 的 pkgs.k8s.io v1.37 源也能用。
- 升级脚本里的装包步骤（unhold → `apt-get install -o Dpkg::Options::=--force-confold kubeadm='1.37.2-*'` → hold，kubelet / kubectl 同样）手工执行通过，`/etc/default/kubelet` 保留，没有 dpkg 提问。
- `kubeadm config validate --config kubeadm-config.yaml`：kubeadm v1.36.6 和 v1.37.2 都输出 `ok`；故意写错字段的报错输出已写进教程；`kubeadm config print init-defaults` 在两个版本都是 `kubeadm.k8s.io/v1beta4`；把 apiVersion 改成 `kubeadm.k8s.io/v1` 时 v1.37.2 报 `experimental API spec ... is not allowed`。
- `kubeadm config images list`：v1.36.6 和 v1.37.2 的输出已写进教程；这 7 个镜像（以及 coredns v1.14.2、etcd 3.6.8-0）在 `registry.aliyuncs.com/google_containers` 上用 registry API 查过 manifest 都存在（对照组：不存在的 tag 返回 404）。
- `etcd/install-etcd-tools.sh`：从华为云镜像装 v3.6.8 和 v3.7.0 都成功；从 etcd.yaml 读版本的逻辑用一个假的清单文件验证过。
- 所有脚本 `shellcheck` + `bash -n` 通过；YAML 用 yamlcheck 检查通过。

验证中发现并已修复：
- containerd 2.3 起 `config default` 生成 `version = 4`，原脚本只认 `version = 3`，直接报错退出。
- `/etc/default/kubelet` 是 kubelet 包的配置文件，`prepare-node.sh` 先写了它，`apt install kubelet` 停在 conffile 提问后失败。装包和升级都加了 `--force-confold`。
- 新版 kubeadm 包不再依赖 cri-tools，原脚本装完没有 `crictl`。现在单独装 cri-tools。
- `install-etcd-tools.sh` 的 EXIT trap 引用了局部变量，`set -u` 下脚本最后以退出码 1 结束（工具其实已装好）。
- `prepare-node.sh` 用 `sed -i` 改 `/etc/hosts`，在 `/etc/hosts` 是挂载点的环境（容器、WSL）里失败，改为原地覆盖。

没有验证（原因）：
- 内核相关的三步：`modprobe br_netfilter`、`swapoff -a`、bridge 相关 sysctl。容器和宿主机共用内核，执行会改到讲师实验机，验证时用垫片跳过了；`chronyc makestep` 在验证时用 `chronyd -x` 禁止调整时钟。这几步的命令都是官方文档写法，需要在虚拟机上确认。
- AppArmor：容器里看不到宿主机的 AppArmor，脚本走的是“未启用”分支；虚拟机上应显示“已启用”。
- `kubeadm init / join`、Calico、`kubeadm upgrade plan / apply / node`、drain / uncordon、证书续期、etcd 备份与恢复、`test/demo-app.yaml`：都需要真集群，按约定不在实验机上执行，留给讲师在 kind / 虚拟机集群上统一验证。教程里这些步骤的输出仍是示意。
- Harbor 拉镜像：实验机上没有 Harbor，只验证了证书和 hosts.toml 落盘位置。
