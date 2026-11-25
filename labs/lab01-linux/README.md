# Lab 01 Linux 基础与常见故障排除实战

对应教程：《DevOps 运维实战》Lab 01 Linux 基础与常见故障排除实战。

在 lab-web1（192.168.56.11）上用 systemd 部署 mall-api，建 LVM 数据盘，然后用故障脚本制造五类常见故障，练习排查套路。

## 文件

| 路径 | 用途 |
|---|---|
| `mall-api.service` | systemd 服务文件，放到 `/etc/systemd/system/mall-api.service`。和 Lab 03 Ansible 模板内容一致 |
| `mall-api.env.example` | 环境变量文件模板，复制到 `/etc/mall-api/mall-api.env`（0640，root:mall） |
| `faults/lib.sh` | 故障脚本公共函数（改环境变量、等健康检查、重启服务），不单独执行 |
| `faults/01-cpu/make.sh` `fix.sh` | 故障 1：CPU 飙高（`/api/debug/cpu`，临时打开 `MALL_DEBUG`） |
| `faults/02-oom/make.sh` `fix.sh` | 故障 2：内存泄漏被 OOM Killer 杀掉（`/api/debug/leak` + systemd `MemoryMax=150M`） |
| `faults/03-disk/make.sh` `fix.sh` | 故障 3：`/data` 写满，以及「删了文件空间不释放」（`lsof +L1`） |
| `faults/04-service/make.sh` `fix.sh` | 故障 4：服务起不来，`config`（端口写错）/ `exec`（二进制没有执行权限）/ `dir`（二进制所在目录 mall 用户进不去）/ `port`（端口被占） |
| `faults/05-port/make.sh` `fix.sh` | 故障 5：端口不通，`firewall`（ufw 没放行 8080，默认 DROP，客户端超时）/ `bind`（只监听 127.0.0.1） |

## 前提

- lab-web1 已按入门基础包初始化（Ubuntu Server 24.04 LTS）。
- mall-api 已按教程 5.2 节部署：`/opt/mall-api/mall-api`、`/etc/mall-api/mall-api.env`、`mall-api.service`，ufw 已放行 OpenSSH 和 8080/tcp 并启用（故障 5 的 firewall 场景要求 ufw 是 active）。
- 脚本用到的命令：`curl` `ufw` `systemd-run` `python3` `fallocate` `ss`，Ubuntu Server 默认都有。
- 故障 3 需要先按教程 5.3 节建好 LVM 并挂载到 `/data`。脚本只写独立挂载的数据盘，不会写根分区。

## 使用

```bash
# 在自己电脑上把整个目录传到 lab-web1
scp -r labs/lab01-linux ops@192.168.56.11:~/

# 在 lab-web1 上
cd ~/lab01-linux/faults
sudo bash 01-cpu/make.sh          # 制造故障，然后自己排查
sudo bash 01-cpu/fix.sh           # 排查完恢复

sudo bash 04-service/make.sh port # 带参数的场景
sudo bash 04-service/fix.sh       # fix 脚本会把该场景所有可能的改动都恢复
```

一次只做一个故障，做完先 fix 再做下一个。每个 fix 脚本都会把 `MALL_DEBUG` 改回 `false`。第一次改环境变量文件时，脚本会备份到 `/etc/mall-api/mall-api.env.lab01.bak`。

## 检查

```bash
cd labs/lab01-linux/faults
shellcheck lib.sh */*.sh
for f in lib.sh */*.sh; do bash -n "$f"; done
```

## 验证记录

验证时间 2026-11-25。环境：ops 服务器上的 Docker 容器（`labv/ubuntu-systemd:24.04`，带 systemd，Ubuntu 24.04.5，systemd 255.4，cgroup v2，`--privileged`，容器内存上限 1G），一个容器当 lab-web1，另一个容器当“学员电脑”，同一个 Docker 网络。mall-api 按 `docs/CONVENTIONS.md` 的命令交叉编译（`-X main.version=v1.0.0`）。笔记里的预期输出来自这次运行，IP 改成了教程规划的 192.168.56.11 / 192.168.56.1，loop 设备名改成了 sdb / sdb1 / sdb2，cgroup 路径去掉了 Docker 前缀。

已验证（真跑通过）：

- 5.1：`file` 输出 x86-64 静态链接。
- 5.2：建 mall 用户和目录、`install` 权限、unit 文件、`ufw allow OpenSSH` + `ufw allow 8080/tcp` + `ufw enable`、`systemctl enable --now`、`/healthz` 200、`/readyz` 503、`/api/version`、从另一台机器访问 8080、journalctl 各种用法、`/var/log/journal` 默认存在、`kill -9` 后 3 秒拉起且 `NRestarts=1`、容器重启后 mall-api 和 ufw 都自动起来。
- 5.3：在 loop 设备上做 parted 分区、pvcreate / vgcreate / lvcreate、mkfs.xfs、fstab（UUID + nofail）+ `mount -a`、边写边 `vgextend` + `lvextend` + `xfs_growfs`（3G → 7G，写入的时间戳没有中断）；另用一个 loop 设备建 `ubuntu-vg/ubuntu-lv`（ext4）模拟系统盘，验证了 `lvextend -r -l +100%FREE`（10G → 20G，自动调 resize2fs）。
- 5.5 五类故障的 make / fix 全部真跑，fix 均可重复执行：
  - 01-cpu：top / top -H / vmstat / ss / inflight 指标 / `MALL_DEBUG=true`。
  - 02-oom：第 4 次请求 `Empty reply from server`，`Failed with result 'oom-kill'`，dmesg 有 `CONSTRAINT_MEMCG` 和 `Memory cgroup out of memory`。
  - 03-disk：`No space left on device`、rm 后 df 不降、`lsof +L1` 看到 `(deleted)`、`truncate /proc/PID/fd/3` 后空间释放。本次把 make.sh 里补满剩余空间的 dd 改成写到满为止（原来只写 2M，xfs 上会剩约 1M，小文件还能写进去，看不到报错）。
  - 04-service：config（`invalid port`，1/FAILURE）、exec（203/EXEC，systemd 255 日志里只有退出码，没有 `Permission denied` 那一行）、dir（新增场景，203/EXEC + `Failed to execute ...: Permission denied`，`sudo -u mall namei -l` 定位）、port（`address already in use`，`systemctl status PID` 找到 `lab01-squatter.service`）。
  - 05-port：firewall（ufw 在 privileged 容器里可用；客户端 ping 通、curl / nc 超时；tcpdump 看到 SYN 每秒重传、无回包）、bind（`Connection refused`，ss 显示 `127.0.0.1:8080`）。另外试了 `ufw reject 8080/tcp`，客户端是 `Connection refused`，写进了笔记的报错对照表。
- 5.6：mall-check.sh 由 cron 在整 5 分钟执行，`journalctl -t mall-check` 有失败记录；cron 的 PATH（Ubuntu 通过 PAM 读 `/etc/environment`，含 `/usr/sbin`）、`%` 没转义（日志里是 `CMD (echo date +)`）、没有 MTA 时 `No MTA installed, discarding output`，都是真实输出。
- `shellcheck lib.sh */*.sh` 和 `bash -n` 全部通过。

没验证 / 只部分验证：

- 真实虚拟机的整机重启：用 `docker restart` 代替。注意容器镜像里 `ufw.service` 默认是 disabled，要手工 `systemctl enable ufw` 才会在重启后自动加载规则；真实的 Ubuntu Server 上默认是 enabled，笔记里加了 `systemctl is-enabled ufw` 的检查。
- 新加虚拟磁盘：用 loop 文件代替真实的 `/dev/sdb`，容器里没有 udev，分区设备节点要手工 mknod，LVM 关了 udev 同步。命令和输出本身和真实磁盘一致，设备名是改写的。
- 真实系统盘 `ubuntu-vg` 的 VFree 有多少、`growpart` + `pvresize`：没有在真实安装的系统盘上做，`ubuntu-vg` 是用 loop 设备模拟的；`growpart` / `pvresize` 没跑。
- `ufw enable` 的交互提示：验证时用的是 `ufw --force enable`，提示文字按 ufw 0.36.2 的原文写。
- `dmesg | grep 'UFW BLOCK'`：容器的网络命名空间里内核不记录 netfilter 日志（`nf_log_all_netns=0`），没看到；真实虚拟机上应能看到，待讲师在虚拟机上确认。
- AppArmor：容器镜像没装 apparmor，容器里也不能加载 profile，`aa-status` 和 `apparmor="DENIED"` 的说明没验证。
- `apt install htop sysstat ...` 在容器里装成功（官方源，未换镜像）；Ubuntu Server 默认已带哪些包没在真实安装上核对。
- strace 排查服务启动的那条命令、`top` 的交互按键、`journalctl -f` 交互，没逐条跑。
- arm64（Apple Silicon）编译和运行没验证。

