# Lab 03 Shell / Python 与 Ansible 自动化

对应教程：《DevOps 运维实战》Lab 03 Shell / Python 与 Ansible 自动化。

把 Lab 02 手工做过的事（装 Nginx、MySQL 主从、Redis、mall-api、Keepalived）变成脚本和 Playbook，换一批新机器一条命令重新部署。

## 文件

| 路径 | 用途 |
|---|---|
| `scripts/inspect.sh` | 服务器巡检：CPU、内存、磁盘、inode、负载、systemd 服务、证书到期。有告警项时退出码 1 |
| `scripts/nginx_log_stats.sh` | Nginx 访问日志统计：Top IP、状态码分布、5xx 接口、慢请求，支持 `.gz` |
| `scripts/mysql_backup.sh` | MySQL 逻辑备份：mysqldump + gzip + 校验 + 清理过期文件，带锁防重入 |
| `scripts/mall_healthcheck.py` | 调用 mall-api 的 `/healthz` `/readyz` `/api/products` 做健康巡检，异常推送企业微信 / 钉钉机器人 |
| `scripts/test_mall_healthcheck.py` | 上面 Python 脚本纯函数的单元测试 |
| `ansible/ansible.cfg` | Ansible 配置（在 `ansible/` 目录下执行命令才生效） |
| `ansible/requirements.yml` | 用到的集合：ansible.mysql、ansible.posix、community.general |
| `ansible/inventory/hosts.ini` | 主机清单，按 web / db_primary / db_replica / redis 分组 |
| `ansible/group_vars/` `ansible/host_vars/` | 变量；密码放 `group_vars/all/vault.yml`（用 ansible-vault 加密，仓库里只有 `.example`） |
| `ansible/roles/common` | 主机名、hosts、时区、基础包（apt）、ufw、内核参数、巡检脚本和定时任务 |
| `ansible/roles/mysql` | MySQL 8.4 LTS（官方 APT 源）安装、`/etc/mysql/mysql.conf.d/mall.cnf`、主库导入 `sql/init.sql`、建账号、从库 GTID 复制、从库定时备份 |
| `ansible/roles/redis` | Redis（官方 APT 源 packages.redis.io，8.x）安装、密码、内存上限、持久化 |
| `ansible/roles/mall_api` | mall-api 二进制、环境变量文件、systemd 服务，部署后等 `/readyz` 通过 |
| `ansible/roles/nginx` | Nginx（nginx.org stable 源）、自签证书、静态页面、`/api/` 反代到两台 mall-api |
| `ansible/roles/keepalived` | Keepalived 单播 VRRP，VIP 192.168.56.10，ufw 放行 VRRP |
| `ansible/site.yml` | 总入口，一条命令部署整套环境 |
| `ansible/first-playbook.yml` | 练手用的第一个 Playbook（chrony、motd、handler、幂等） |

## 快速使用

```bash
# 1. 脚本检查（任意 Linux）
cd labs/lab03-automation/scripts
shellcheck *.sh && bash -n inspect.sh
python3 -m unittest -v test_mall_healthcheck.py

# 2. 控制节点准备（在 labs/lab03-automation/ansible 目录）
python3 -m venv ~/ansible-venv && source ~/ansible-venv/bin/activate
pip install ansible-core -i https://pypi.tuna.tsinghua.edu.cn/simple
ansible-galaxy collection install -r requirements.yml -p ./collections

# 3. 编译 mall-api（仓库根目录）
cd app && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w -X main.version=v1.0.0" -o mall-api . && cd -

# 4. 密码
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
vi group_vars/all/vault.yml
ansible-vault encrypt group_vars/all/vault.yml

# 5. 部署
ansible all -m ping
ansible-playbook site.yml --ask-vault-pass --check --diff   # 已部署过的环境先预演
ansible-playbook site.yml --ask-vault-pass
```

## 注意

- 角色按 Ubuntu Server 24.04 LTS 编写，`common` 角色第一步会检查系统版本。
- 控制节点用 pip 把 ansible-core 装进虚拟环境。Ubuntu 24.04 的 Python 是 3.12，pip 会自动装支持 3.12 的最新版（写作时 2.21.x，ansible-core 2.22 要求 Python 3.13）。Ubuntu 软件源里的 ansible-core 是 2.16，偏旧。
- vault.yml 加密以后，`ansible all -m ping` 这类 ad-hoc 命令也要带 `--ask-vault-pass`（会加载 group_vars）。
- MySQL root 用 auth_socket 认证（官方 APT 包非交互安装的默认行为），所以 vault 里没有 root 密码。
- `keepalived_interface`（默认 `enp0s8`）按自己虚拟机的网卡名改，在 `group_vars/web.yml`。
- 自签证书在控制节点生成到 `ansible/files/certs/`，私钥已被 `.gitignore` 忽略，不要提交。

## 验证记录

验证时间：2026-11-25。环境：一台 Ubuntu 24.04（4C16G）上用 Docker 起 5 个带 systemd 的 Ubuntu 24.04 容器（控制节点 + lab-web1/web2/db1/db2），网段换成 192.168.57.0/24，用 `-i` 和 `-e @verify-vars.yml` 覆盖 IP、VIP、网卡名（eth0）。控制节点 pip 装的 ansible-core 2.21.6（Python 3.12），集合 ansible.mysql 5.2.1、ansible.posix 2.2.2、community.general 14.0.1。

已验证：

- `shellcheck`（0.9.0）、`bash -n` 全部脚本通过；`python3 -m unittest test_mall_healthcheck.py` 17 个用例通过。
- `first-playbook.yml` 第一次 changed=5，第二次 changed=0。
- 4 台全新机器 `site.yml` 一次成功（failed=0，约 3 分钟）；第二次执行 4 台全部 changed=0；已部署环境 `--check --diff` 全部 changed=0；改模板后 `--check --diff --limit lab-web1 --tags nginx` 能看到 diff。
- 实际装上的版本：MySQL 8.4.13（官方 APT 源 mysql-8.4-lts）、Nginx 1.30.x（nginx.org stable）、Redis（当时是 Ubuntu universe 的 7.0.15，之后 redis 角色改成了官方源，见下一条）、Keepalived（Ubuntu 源）。GTID 主从复制 IO/SQL 线程 Yes，下单后从库同步；经 VIP 走 HTTPS 访问正常。
- redis 角色改用 Redis 官方 APT 源（packages.redis.io）后单独复验：全新 Ubuntu 24.04 容器上 `site.yml --limit lab-db1 --tags redis` 第一次 changed=5、第二次 changed=0；装上 Redis 8.12.0（`6:8.12.0-1rl1~noble1`），`/etc/apt/sources.list.d/redis.sources` 为 DEB822 格式，公钥 `/etc/apt/keyrings/redis.asc`；无密码 `NOAUTH`、带密码 `PONG`，ufw 6379 只对实验网段放行。没有重跑整套 `site.yml`：教程里整套执行的 lab-db1 统计（ok=39 changed=29、第二次 ok=35 changed=0）是在原实测数字上加了 redis 角色新增的 3 个任务（加源 changed、读版本、断言），不是重新实测的。
- 停 lab-web1 的 Nginx，VIP 约 5 秒漂到 lab-web2，恢复后抢回；ufw 规则、before.rules 里的 VRRP 放行生效。
- `--tags mall_api -e mall_version=v1.0.1` 滚动升级，期间每 0.2 秒一个请求，352 个全部 200。
- ansible-vault：encrypt / view / encrypt_string；加密后 ad-hoc 不带 vault 密码会报 `no vault secrets found`。
- inspect.sh（正常、停服务告警退出码 1）、nginx_log_stats.sh（含慢请求一节）、mysql_backup.sh（备份、sha256 校验、flock 防重入）、mall_healthcheck.py（正常、Redis 停掉告警、持续异常不重复、恢复通知；只打印，没配 Webhook）。

验证中发现并已修改：

- MySQL APT 公钥 `RPM-GPG-KEY-mysql-2023` 已过期（EXPKEYSIG），改用 `RPM-GPG-KEY-mysql-2025`；包名写 `mysql-community-server`，防止源没生效时装成 Ubuntu 的 8.0。
- MySQL 8.4 默认不加载 mysql_native_password，`mysql_user` 的 `password` 参数会报错；改成 `caching_sha2_password` + `plugin_auth_string` + 固定 `salt`（同时保证幂等）。
- 只读查询任务加 `check_mode: false`，否则 `--check` 时后续任务拿不到结果。
- 备份脚本加 `umask 077`，备份文件原来是 644。

没有验证（原因）：

- 企业微信 / 钉钉真实推送：规定不往真实群发消息，只验证了 dry-run 和“无 Webhook 时打印”。
- 真实虚拟机的 enp0s8 网卡、VirtualBox 网络：用的是容器和 eth0。
- 容器环境的差异：`/etc/hosts` 是 Docker 挂载的，验证前在容器里 `umount /etc/hosts`；chrony 加了 `-x`（不调宿主机时钟）；`vm.swappiness`、`vm.overcommit_memory` 是整机参数，验证时用 `common_sysctl`、`redis_set_overcommit_memory: false` 跳过。这三项在真实虚拟机上不需要。
- 教程里 inspect.sh 的 CPU、内存数字来自 4C16G 的宿主机，不是 1C2G 虚拟机。
