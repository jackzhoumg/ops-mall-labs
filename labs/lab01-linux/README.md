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
| `faults/04-service/make.sh` `fix.sh` | 故障 4：服务起不来，`config`（端口写错）/ `exec`（二进制没有执行权限）/ `port`（端口被占） |
| `faults/05-port/make.sh` `fix.sh` | 故障 5：端口不通，`firewall`（firewalld 没放行）/ `bind`（只监听 127.0.0.1） |

## 前提

- lab-web1 已按入门基础包初始化（Rocky Linux 9，firewalld 开启）。
- mall-api 已按教程 5.2 节部署：`/opt/mall-api/mall-api`、`/etc/mall-api/mall-api.env`、`mall-api.service`，并放行了 8080/tcp。
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
