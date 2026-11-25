# labs/basics：入门基础包用到的脚本

对应教程：入门基础包《基础-1 实验环境搭建》。

| 文件 | 用途 |
|---|---|
| `init-vm.sh` | 新装或克隆的 Rocky Linux 9 虚拟机一键初始化：主机名、`/etc/hosts`、阿里云软件源、常用工具、时区与时间同步、`ops` 用户、firewalld / SELinux、Host-Only 网卡静态 IP |

## 用法

先把脚本传到虚拟机上（在自己电脑上执行，IP 换成虚拟机当前 DHCP 拿到的地址）：

```bash
scp labs/basics/init-vm.sh ops@192.168.56.101:~
```

在虚拟机上执行：

```bash
# 新装的虚拟机
sudo bash init-vm.sh lab-web1 192.168.56.11

# 克隆出来的虚拟机：额外重置 machine-id 和 SSH 主机密钥
sudo bash init-vm.sh --clone lab-web2 192.168.56.12

# 只打印 hosts 内容，贴到自己电脑的 hosts 文件
bash init-vm.sh --print-hosts 192.168.56
```

参数里的 IP 是要配置成的静态 IP。网段取 IP 的前三段，hosts 里所有机器都按这个网段生成，所以 Apple Silicon + UTM（常见网段 `192.168.64.0/24`）直接写 `192.168.64.11` 就行。

## 可选环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `LAB_IFACE` | 自动识别 | 要配静态 IP 的网卡名，如 `enp0s8` |
| `LAB_PREFIX` | `24` | 掩码位数 |
| `LAB_SKIP_IP` | `0` | 设为 `1` 不改 IP。**云服务器必须设置** |
| `LAB_SKIP_MIRROR` | `0` | 设为 `1` 不换源（云服务器一般已有内网源） |
| `LAB_MIRROR_URL` | `https://mirrors.aliyun.com/rockylinux` | 镜像地址，也可换成清华、中科大等 |
| `LAB_SELINUX` | `enforcing` | 也可设 `permissive`，不提供 `disabled` |
| `LAB_FIREWALL` | `on` | 也可设 `off` |
| `LAB_MALL_HOST` | `10` | `mall.lab.local` 指向 `.10`（Lab 02-03 的 VIP）还是 `.200`（Lab 06 起的 K8s 网关） |

带环境变量的写法：`sudo LAB_SKIP_IP=1 LAB_SKIP_MIRROR=1 bash init-vm.sh lab-web1 10.0.0.11`。

## 设计说明

- 可重复执行：hosts 用标记块整块替换；换源只改还指向官方地址的 `rocky*.repo`，原文件备份到 `/etc/yum.repos.d/backup-<时间>/`。
- 换源写法来自阿里云镜像站 Rocky Linux 页面。页面示例写的是 `Rocky-*.repo`（Rocky 8 文件名），Rocky 9 的文件名是小写 `rocky.repo`、`rocky-extras.repo` 等，脚本按 9 的文件名处理。
- SELinux 和 firewalld 默认保持开启，理由写在脚本开头的注释里。
- 静态 IP 放在最后一步，SSH 断开不影响前面的配置。

## 检查

```bash
shellcheck labs/basics/init-vm.sh
bash -n labs/basics/init-vm.sh
```
