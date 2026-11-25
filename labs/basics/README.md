# labs/basics：入门基础包用到的脚本

对应教程：入门基础包《基础-1 实验环境搭建》（基础-2、基础-3、基础-4 用到的工具也由它装好）。

| 文件 | 用途 |
|---|---|
| `init-vm.sh` | 新装或克隆的 Ubuntu Server 24.04 虚拟机一键初始化：主机名、`/etc/hosts`、阿里云 DEB822 软件源、常用工具、时区与时间同步、`ops` 用户、ufw / AppArmor、netplan 配 Host-Only 网卡静态 IP |

## 用法

先把脚本传到虚拟机上（在自己电脑上执行，IP 换成虚拟机当前 DHCP 拿到的地址）：

```bash
scp labs/basics/init-vm.sh ops@192.168.56.101:~
```

在虚拟机上执行：

```bash
# 新装的虚拟机（模板机只初始化，不改 IP）
sudo LAB_SKIP_IP=1 bash init-vm.sh ubuntu-template 192.168.56.100

# 克隆出来的虚拟机：额外重置 machine-id 和 SSH 主机密钥
sudo bash init-vm.sh --clone lab-web1 192.168.56.11

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
| `LAB_SKIP_APPLY` | `0` | 设为 `1` 时写好 netplan 配置并 `netplan generate` 检查，但不 `netplan apply` |
| `LAB_SKIP_MIRROR` | `0` | 设为 `1` 不换源（云服务器一般已有内网源） |
| `LAB_MIRROR_URL` | amd64：`https://mirrors.aliyun.com/ubuntu`；arm64：`https://mirrors.aliyun.com/ubuntu-ports` | 镜像地址，也可换成清华、中科大等 |
| `LAB_FIREWALL` | `on` | `on`：放行 SSH 后开启 ufw；`off`：关闭 ufw |
| `LAB_MALL_HOST` | `10` | `mall.lab.local` 指向 `.10`（Lab 02-03 的 VIP）还是 `.200`（Lab 06 起的 K8s 网关） |

带环境变量的写法：`sudo LAB_SKIP_IP=1 LAB_SKIP_MIRROR=1 bash init-vm.sh lab-web1 10.0.0.11`。

## 设计说明

- 只支持 Ubuntu 24.04（检查 `/etc/os-release`），amd64 和 arm64 自动选对应的镜像仓库（arm64 的包在 `ubuntu-ports`）。
- 可重复执行：hosts 用标记块整块替换；软件源内容和目标一致时不动；netplan 只写自己的 `/etc/netplan/60-ops-lab.yaml`（整份覆盖），不改安装程序生成的 `50-cloud-init.yaml`，靠文件名顺序覆盖其中的 `dhcp4: true`。
- 换源：写法来自阿里云镜像站 Ubuntu 页面的“DEB822 配置方法”。只替换还指向官方源（archive / security / ports.ubuntu.com）或阿里云的 `ubuntu.sources`，云厂商改过的源不碰；原文件备份到 `/etc/apt/backup-<时间>/`（放在 `sources.list.d` 外面，避免 apt 读到重复的源）。
- `/etc/hosts`：本机主机名在课程区块里且指向本机静态 IP 时，删掉安装程序写的 `127.0.1.1` 行，让 `getent hosts lab-web1` 返回 `192.168.56.11`；否则把 `127.0.1.1` 行改成新主机名。
- ufw 默认开启，顺序是先 `ufw allow OpenSSH` 再 `ufw --force enable`；AppArmor 不改，只打印状态。取舍理由写在脚本开头的注释里。
- 时间同步用 Ubuntu 默认的 systemd-timesyncd（`timedatectl set-ntp true`），不装 chrony。
- 静态 IP 放在最后一步，SSH 断开不影响前面的配置。写完先 `netplan generate`，失败就还原 `60-ops-lab.yaml` 并退出，不留坏配置。
- 云服务器：`root` 或 `ubuntu` 用户的 `authorized_keys` 会复制给 `ops`；有 `/etc/cloud/cloud.cfg.d` 时写 `preserve_hostname: true`，防止重启后主机名被 cloud-init 改回去。

## 检查

```bash
shellcheck labs/basics/init-vm.sh
bash -n labs/basics/init-vm.sh
```

## 验证记录

验证环境：讲师实验机 ops（Ubuntu 24.04.4 宿主机）上的 Docker 容器 `labv/ubuntu-systemd:24.04`（容器内 Ubuntu 24.04.5 LTS，amd64，带 systemd），每个容器内存限制 512M。容器网段 172.30.1.0/24，教程里的输出已按课程规划把 172.30.1.11 改写成 192.168.56.11、宿主机网关 172.30.1.1 改写成 192.168.56.1、eth0 改写成 enp0s8。验证日期 2026-11-25。

为了让容器尽量接近“刚装好的 Ubuntu Server”，运行脚本前在容器里做了这些准备（只在容器内，宿主机未做任何改动）：解开 Docker 绑定挂载的 `/etc/hostname` 和 `/etc/resolv.conf`；安装 Ubuntu Server 默认就有的 `netplan.io`、`systemd-resolved`、`rsyslog`；删除 Docker 镜像里的 `/usr/sbin/policy-rc.d`（否则装完 nginx 不会自动启动）；用 dummy 网卡 `enp0s8`（预先配 192.168.56.101/24）模拟 VirtualBox 的 Host-Only 网卡；写一份 `enp0s8: dhcp4: true` 的 `50-cloud-init.yaml` 模拟安装程序；在 hosts 里加 `127.0.1.1 ubuntu-template`。

### init-vm.sh：已验证

- `shellcheck`、`bash -n` 通过。
- 在全新容器里按教程顺序端到端执行：模板机 `LAB_SKIP_IP=1 ... ubuntu-template 192.168.56.100` → `--clone lab-web1 192.168.56.11`（`LAB_SKIP_APPLY=1`）→ 再执行一次。三次退出码都是 0。
- 换源：`ubuntu.sources` 改成阿里云 DEB822 两段，原文件备份到 `/etc/apt/backup-*/`，`apt-get update` 正常；第二次执行显示“软件源已经是 ...，不用改”。
- 软件包全部装上（包括 universe 里的 shellcheck），没有“找不到”的包。
- `/etc/hosts`：课程区块只有一份；模板机保留 `127.0.1.1 ubuntu-template`；克隆后 127.0.1.1 行被删除，`getent hosts lab-web1` 返回 `192.168.56.11`，`sudo` 正常。
- ufw：`Status: active`，只有 OpenSSH（v4/v6）两条规则，`ufw.service` 为 active；重复执行不会多出规则。
- 克隆：SSH 主机密钥重新生成（指纹改变），主机名改为 lab-web1。
- netplan：自动选中了已有 192.168.56.x 地址的 `enp0s8`；生成的 `60-ops-lab.yaml` 权限 600；`netplan generate` 通过；`netplan get ethernets` 合并结果是 `dhcp4: false` + `192.168.56.11/24`（确认 60 覆盖了 50 的 `dhcp4: true`）；`/run/systemd/network/10-netplan-enp0s8.network` 内容正确；`networkctl reload` 后 systemd-networkd 把 `enp0s8` 从 .101 换成 .11，路由表多出 `192.168.56.0/24 dev enp0s8 proto kernel scope link src 192.168.56.11`，没有新增默认路由。
- 单网卡分支（UTM 场景）：`LAB_IFACE=eth0 LAB_SKIP_APPLY=1` 生成了带 `routes: - to: default via 网关` 和 `nameservers` 的配置，`netplan generate` 通过（只生成，未应用，避免断开容器网络）。
- 坏配置回滚：在 `/etc/netplan/` 放一个带 Tab 的 YAML，脚本报“netplan generate 失败，已还原”，`60-ops-lab.yaml` 内容不变。
- 参数检查：主机名带下划线时报错退出；`--print-hosts` 输出正确。
- 幂等：第三次执行前后 `/etc/hosts`、`ubuntu.sources`、`60-ops-lab.yaml` 的 md5 和 ufw 规则完全一致。

### init-vm.sh：没有验证 / 容器里验证不了的

- `netplan apply` / `netplan try`：容器里没有 udev，`netplan apply` 在 `udevadm control --reload` 处失败，所以改用 `LAB_SKIP_APPLY=1` 只验证生成的配置，并用 `networkctl reload` 验证 systemd-networkd 能正确应用。真机上通过 SSH 执行时连接会断开、需要用新 IP 重连，这一步需要在 VirtualBox / UTM 虚拟机上确认。
- machine-id 重置：脚本确实删除并重建了 `/etc/machine-id`（文件时间变了），但容器里 `systemd-machine-id-setup` 从宿主机的 SMBIOS UUID 生成，新旧值相同。虚拟机克隆后硬件 UUID 不同，预期会得到新值，需要在虚拟机上确认。
- AppArmor：容器里没有 AppArmor，脚本打印的是 warn 分支；“已开启”分支没有跑到。
- 时间同步：`timedatectl set-ntp true` 执行成功，但 systemd-timesyncd 在容器里按设计不运行，没有验证实际同步。
- arm64：没有 arm64 环境，`ubuntu-ports` 分支只按阿里云镜像站文档编写。
- cloud-init `preserve_hostname`：只验证了文件写入，没有在云服务器上验证重启后的效果；`/home/ubuntu/.ssh/authorized_keys` 复制分支没有跑到。
- 安装向导（subiquity）各页面、LVM 默认只分一半空间、`lvextend` 扩容、VirtualBox / UTM 的界面操作：没有虚拟机，按 Ubuntu 官方文档和安装程序的已知行为编写，未实操。

### 教程里的命令：已验证

- 基础-1：`sshd_config.d` 文件顺序（`50-lab.conf` 时 `sshd -T` 仍是 `passwordauthentication yes`，改名 `00-lab.conf` 后为 `no`）、`sshd -t`、`systemctl reload ssh`、`netplan get`、阿里云 DEB822 源、hosts 中没有本机记录时 systemd-resolved 把主机名解析成本机 `fe80::` 地址。
- 基础-2：5.1-5.8 全部命令和练习 1-8 的参考答案都在容器里以 ops 身份跑过，教程里标“实测”的输出来自这次运行（umask 0002、`dpkg -S /etc/ssh/sshd_config` 查不到、`journalctl -u sshd` 为 `-- No entries --`、nginx 装完自动启动、`ufw allow 80/tcp`、`ufw app list`、access.log 统计、`check.sh` / `backup.sh` 通过 shellcheck 且输出符合预期、crontab、CRLF 报错信息、vim 非交互替换）。
- 基础-3：`ip route get`、nsswitch、resolv.conf、`dig`（含 `-4 +trace`、`@223.5.5.5`、hosts 经 systemd-resolved 返回）、`getent`、python http.server、`curl -v`（200 / 404 / 拒绝连接）、`tcpdump -i lo` 抓握手和挥手、`ss -tan state time-wait`、8081 的 SYN/RST、从宿主机（模拟学员电脑）访问时 ufw 丢包超时、放行后在网卡上抓包、`ping`、`ss -tnlp`、`nc -zv`、练习 5.6 的“只监听 127.0.0.1”两种情况（ufw 未放行时超时，放行后立刻失败）。
- 基础-4：5.1-5.5 的 Git 练习（配置、提交、diff、Fast-forward、冲突、`log --graph`、reset / revert、`.gitignore`、`check-ignore`、reflog 找回）在容器里跑过，Git 2.43.0，教程里的 commit 号来自这次运行。

### 教程里的命令：没有验证

- 基础-1：VirtualBox / UTM 建虚拟机、安装向导、快照和克隆的界面操作；`ip -br addr`、`50-cloud-init.yaml` 内容、`id` 输出中的组列表（按安装程序默认行为编写）；`lvextend`；`ssh-copy-id` 和自己电脑上的操作；云服务器部分。
- 基础-2：`crontab -e` 第一次运行时选择编辑器的交互（用 `crontab -` 写入代替）；`Command 'xxx' not found` 提示（容器里没装 command-not-found）；虚拟机上 `/boot` 等分区在 `check.sh` 里的输出。
- 基础-3：`ip -br addr` / `ip route` 中 NAT 网卡（enp0s3、10.0.2.x）的行和 `resolvectl status` 里上游 10.0.2.3，是按 VirtualBox 默认值改写的示意；真实上游是 Docker 内置 DNS。`ss -tnlp` 去掉了 Docker 内置 DNS 和前一篇留下的 nginx 两类行。`dig +trace` 在国内网络下的表现没有验证（验证机不在国内）。
- 基础-4：GitHub 注册、SSH key 添加、`ssh -T git@github.com`、fork、clone、push、Gitee 导入、Sync fork 都需要真实账号，没有验证。
