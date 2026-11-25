# Lab 05 K8s 集群搭建与日常维护
对应教程：《DevOps 运维实战》Lab 05 K8s 集群搭建与日常维护。

用 kubeadm 搭一套 1 master + 2 worker 的集群（containerd 2.x + Calico），先装 v1.35，再按官方流程升级到 v1.36；练节点维护、证书续期、etcd 备份恢复。

## 机器
| 主机名 | IP | 配置 |
|---|---|---|
| k8s-master | 192.168.56.21 | 2C4G |
| k8s-node1 | 192.168.56.22 | 2C4G |
| k8s-node2 | 192.168.56.23 | 2C4G（实验里后加入，练扩容） |

另外要用到 Lab 04 的 Harbor（lab-dev 192.168.56.15）。

## 文件
| 路径 | 用途 | 在哪执行 |
|---|---|---|
| `prepare-node.sh` | 主机名、hosts、关 swap、overlay / br_netfilter、sysctl、chrony、SELinux、防火墙、kubelet `--node-ip` | 每台节点 |
| `install-containerd.sh` | 从 Docker CE 源装 containerd.io 2.x，生成 config.toml，改 SystemdCgroup / sandbox / config_path，写 Harbor hosts.toml | 每台节点 |
| `containerd/config-k8s.toml` | containerd 2.x 里 K8s 要改的三处配置，手工改时对照 | — |
| `containerd/certs.d/harbor.lab.local/hosts.toml` | Harbor 自签证书配置 | 复制到 `/etc/containerd/certs.d/harbor.lab.local/` |
| `containerd/certs.d/docker.io/hosts.toml.example` | Docker Hub 加速模板 | 按需 |
| `install-kube.sh` | 配 pkgs.k8s.io / 阿里云源，装 kubeadm、kubelet、kubectl 并锁版本；`REPO_ONLY=true` 只换源 | 每台节点 |
| `kubeadm-config.yaml` | `kubeadm init` 配置：版本、controlPlaneEndpoint、podSubnet、国内镜像仓库 | k8s-master |
| `calico/custom-resources.yaml` | Calico（Tigera Operator）安装参数，Pod 网段 10.244.0.0/16 | k8s-master |
| `etcd/install-etcd-tools.sh` | 装和集群同版本的 etcdctl / etcdutl | k8s-master |
| `etcd/etcd-backup.sh` | etcd 快照备份 + 校验 + 清理 | k8s-master（可放 cron） |
| `etcd/etcd-restore.sh` | etcd 快照恢复（需 `CONFIRM=yes`） | k8s-master |
| `upgrade/upgrade-control-plane.sh` | 控制平面 v1.35 → v1.36，每步停下确认 | k8s-master |
| `upgrade/upgrade-node.sh` | 工作节点升级，drain / uncordon 提示到 master 上执行 | 每台工作节点 |
| `test/demo-app.yaml` | 从 Harbor 拉 mall-api 跑 3 副本 + PDB，验证网络、证书和 drain | k8s-master |

## 快速使用
```bash
# 每台节点（主机名和 IP 按本机改）
sudo NODE_NAME=k8s-master NODE_IP=192.168.56.21 ./prepare-node.sh
scp ops@192.168.56.15:/data/cert/ca.crt /tmp/harbor-ca.crt
sudo HARBOR_CA=/tmp/harbor-ca.crt ./install-containerd.sh
sudo ./install-kube.sh                      # 默认 v1.35、阿里云镜像

# k8s-master
sudo kubeadm init --config kubeadm-config.yaml --upload-certs
mkdir -p ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown "$(id -u):$(id -g)" ~/.kube/config
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.33.1/manifests/v3_projectcalico_org-v1beta1.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.33.1/manifests/tigera-operator.yaml
kubectl create -f calico/custom-resources.yaml

# 工作节点：用 init 输出的 kubeadm join 命令
```

## 写作时版本（以官方最新文档为准）
| 组件 | 版本 | 来源 |
|---|---|---|
| Kubernetes | v1.35.10 → v1.36.6 | pkgs.k8s.io / mirrors.aliyun.com/kubernetes-new |
| containerd | 2.4.2（containerd.io 包） | download.docker.com/linux/rhel/9 |
| Calico | v3.33.1（Tigera Operator） | docs.tigera.io |
| etcd | 3.6.6（v1.35）→ 3.6.8（v1.36） | kubeadm 源码 constants.go |
| pause | 3.10.1（v1.35）→ 3.10.2（v1.36） | kubeadm 源码 constants.go |

## 注意
- 脚本都可以重复执行；`etcd-restore.sh` 会让集群回到快照时刻，只在演练时用。
- Calico 写作时对 K8s 1.34/1.35 和 1.36+ 提供两份 CRD 清单（`v3_projectcalico_org-v1beta1.yaml` 和 `v3_projectcalico_org.yaml`），集群升级到 1.36 后按 Calico 升级文档处理。
