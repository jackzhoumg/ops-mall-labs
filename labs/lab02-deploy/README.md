# Lab 02 商城上线：Nginx + MySQL + Redis
对应教程：《DevOps 运维实战》Lab 02 商城上线：Nginx + MySQL + Redis。系统：Ubuntu Server 24.04 LTS。
这里的配置是手工部署用的“最终版”，路径、文件名、账号和 Lab 03 的 Ansible 角色（`labs/lab03-automation/ansible/`）一致。Lab 03 用 Ansible 重放这一课时，生成的配置和这里一样。
| 文件 | 放到哪台机器、哪个路径 | 用途 |
|---|---|---|
| `mysql/mysql.sources` | lab-db1、lab-db2：`/etc/apt/sources.list.d/` | MySQL 8.4 LTS 官方 APT 源（DEB822），公钥 `/etc/apt/keyrings/mysql.asc` |
| `mysql/mall-primary.cnf` | lab-db1：`/etc/mysql/mysql.conf.d/mall.cnf` | 主库配置：server-id=1、binlog、GTID、慢日志 |
| `mysql/mall-replica.cnf` | lab-db2：`/etc/mysql/mysql.conf.d/mall.cnf` | 从库配置：server-id=2、relay-log、read_only |
| `mysql/01-primary-accounts.sql` | lab-db1 执行 | 建复制账号 `repl`、备份账号 `backup` |
| `mysql/02-replica-setup.sql` | lab-db2 执行 | GTID 自动定位接上主库 |
| `mysql/mysql-backup.cnf.example` | lab-db1、lab-db2：`/etc/ops/mysql-backup.cnf` | 备份账号密码文件，权限 600 |
| `mysql/mysql_full_backup.sh` | lab-db2：`/usr/local/bin/`，cron 每天 02:30 | mysqldump 全备到 `/data/backup/mysql` |
| `mysql/mysql_pitr.sh` | lab-db1 | 误删恢复：找误操作位置、生成全备 + binlog 回放 SQL（不自动执行） |
| `redis/redis.sources` | lab-db1：`/etc/apt/sources.list.d/` | Redis 官方 APT 源 packages.redis.io（DEB822），公钥 `/etc/apt/keyrings/redis.asc` |
| `redis/redis.conf` | lab-db1：`/etc/redis/redis.conf` 里改这几项 | 密码、监听地址、内存上限、AOF |
| `redis/sentinel.conf.example` | 可选练习 | 哨兵关键配置 |
| `certs/gen-cert.sh` | lab-web1 执行一次，证书拷到两台 `/etc/nginx/ssl/` | 自签证书，带 SAN |
| `nginx/nginx.sources` | lab-web1、lab-web2：`/etc/apt/sources.list.d/` | nginx.org stable 官方源（DEB822），公钥 `/etc/apt/keyrings/nginx.asc` |
| `nginx/99nginx` | lab-web1、lab-web2：`/etc/apt/preferences.d/` | 固定用 nginx.org 的包 |
| `nginx/mall.conf` | lab-web1、lab-web2：`/etc/nginx/conf.d/mall.conf` | 静态页、`/api/` 反代、upstream、HTTPS、ops 日志格式 |
| `keepalived/keepalived-master.conf` | lab-web1：`/etc/keepalived/keepalived.conf` | VRRP 主，优先级 100 |
| `keepalived/keepalived-backup.conf` | lab-web2：`/etc/keepalived/keepalived.conf` | VRRP 备，优先级 90 |
| `keepalived/check_nginx.sh` | lab-web1、lab-web2：`/etc/keepalived/check_nginx.sh` | Nginx 健康检查 |
## 软件版本（写作时）
| 软件 | 来源 | 版本 |
|---|---|---|
| MySQL | repo.mysql.com `mysql-8.4-lts`，包名 `mysql-community-server`，服务 `mysql` | 8.4.13 |
| Redis | packages.redis.io，包名 `redis-server` `redis-tools`，服务 `redis-server` | 8.12.0（`6:8.12.0-1rl1~noble1`） |
| Nginx | nginx.org stable，服务 `nginx` | 1.30.8 |
| Keepalived | Ubuntu 24.04 官方源 | 2.2.8 |
| Percona XtraBackup（可选） | repo.percona.com `pxb-84-lts` | 8.4.0-8 |
## 密码
所有密码都是实验默认值，和 Lab 03 `group_vars/all/vault.yml.example` 一致：
| 账号 | 默认密码 |
|---|---|
| MySQL root | 不设密码，`auth_socket` 认证，只能本机 `sudo mysql` 登录 |
| MySQL mall（应用） | `MallPass123`（`sql/init.sql` 里建的） |
| MySQL repl（复制） | `ChangeMe-Repl-123` |
| MySQL backup（备份） | `ChangeMe-Backup-123` |
| Redis | `ChangeMe-Redis-123` |
| Keepalived 认证 | `mall2026` |
改了密码的话，SQL 文件、`mysql-backup.cnf`、`redis.conf`、`/etc/mall-api/mall-api.env` 要一起改，到 Lab 03 再写进 vault。
## 网卡和网段
默认 VirtualBox Host-Only 网段 `192.168.56.0/24`，Ubuntu 24.04 上第二块网卡一般叫 `enp0s8`。VMware、UTM、云服务器不一样，用 `ip -br addr` 查看后替换 IP 和网卡名。
## 检查
```bash
shellcheck certs/gen-cert.sh mysql/*.sh keepalived/check_nginx.sh
bash -n certs/gen-cert.sh mysql/*.sh keepalived/check_nginx.sh
# 在 web 机器上
sudo nginx -t
# 在 web 机器上
sudo keepalived -t -f /etc/keepalived/keepalived.conf
```
## 验证记录
验证时间：2026-11-25。环境：一台 Ubuntu 24.04（4C16G）上用 Docker 起 4 个带 systemd 的 Ubuntu 24.04 容器模拟 lab-web1 / lab-web2 / lab-db1 / lab-db2，Docker 网络 192.168.56.0/24，IP 和教程规划一致（.11 / .12 / .13 / .14，VIP .10）。mall-api 用 `app/` 交叉编译的 v1.0.0。

已验证（教程里的预期输出已换成这次的真实输出，时间、GTID UUID 以实际为准）：
- MySQL：DEB822 源 + `RPM-GPG-KEY-mysql-2025` 公钥，装上 8.4.13；非交互安装 root 是 `auth_socket`、没有 validate_password 组件，`init.sql` 直接能导；`mall.cnf` 生效（server_id、GTID、`mysql-bin`、慢日志 `/var/log/mysql/mysql-slow.log`）；三个账号都是 `caching_sha2_password`。
- GTID 主从：IO/SQL 线程 Yes、`Auto_Position: 1`；主库写从库可见；mall 账号写从库报 `--read-only`。
- 主从延迟：从库 `LOCK TABLES ... READ` 时 `Seconds_Behind_Source` 涨到 15，Retrieved 1-27 / Executed 1-12，PROCESSLIST 里复制 worker 在 `Waiting for table metadata lock`；解锁后回到 0。
- 备份：`mysql_full_backup.sh` 在 lab-db2 生成 `.sql.gz` 和 `.sha256`，文件头有 `GTID_PURGED` 和 `CHANGE REPLICATION SOURCE TO`；cron 文件已建。
- 误删恢复：lab-db1 全备 → 插 3 条 → `DROP TABLE mall.orders` → `mysql_pitr.sh start-pos / find-drop / extract` → 导入，订单 `COUNT/MAX(id)` 与删表前一致（24/24），从库同步一致、复制正常。`mysqlbinlog` 用的是 mysql-community 包自带的。
- XtraBackup（可选）：percona-release + `pxb-84-lts` 装上 8.4.0-8，对 8.4.13 `--backup`、`--prepare` 都 `completed OK!`。
- Redis：官方源装上 8.12.0，配置文件 `/etc/redis/redis.conf`（redis:redis 640）、服务 `redis-server`；无密码 `NOAUTH`、带密码 `PONG`；`aof_enabled:1`，`appendonlydir/` 多文件 AOF；`kill -9` 后 systemd（`Restart=always`）拉起，数据还在。
- mall-api：两台 `/readyz` 200，mysql 和 redis 都 ok。
- Nginx 1.30.8：`http2 on` 生效（curl 走 HTTP/2）；80 跳 301；证书 SAN 是 `DNS:mall.lab.local, IP Address:192.168.56.10`；20 个请求两台各 10 个；`X-Cache` MISS→HIT；请求 ID 能在 `journalctl -u mall-api` 里找到；access.log 最后两列是上游耗时和总耗时；下单 201。
- 502 / 504：停一台全 200（日志里有 `Connection refused` 和 `0.000, 0.000` 两段上游耗时）；停两台 502，error.log 出现 `no live upstreams`；ufw 删掉 lab-web2 的 8080 放行后，落到它的请求慢 3 秒（`proxy_connect_timeout`）再重试成功，error.log 是 `upstream timed out ... while connecting to upstream`；`slow?ms=35000` 返回 504、耗时 60.06 秒，上游耗时 `30.030, 30.022`。
- Keepalived 2.2.8：`/etc/ufw/before.rules` 放行 VRRP 后 VIP 在 lab-web1；停 lab-web1 的 Nginx，客户端循环里约 5.5 秒（11 个 0.5 秒间隔）返回 000，之后 200，VIP 到了 lab-web2；启动 Nginx 后约 5 秒抢回。

没有验证（原因）：
- Redis 哨兵（可选练习）：时间有限，没做。
- 真实虚拟机相关：网卡是容器的 `eth0`（验证时把配置里的 `enp0s8` 替换成 `eth0`），VirtualBox 混杂模式、自己电脑浏览器访问和证书导入都没测；“自己电脑”的循环请求是在 lab-db1 容器里跑的。
- `vm.overcommit_memory`：整机内核参数，在容器里改会改到宿主机，没有执行；Redis 日志里因此有 `WARNING Memory overcommit must be enabled!`，真实虚拟机上照教程执行即可。
- 5.1 用 `init-vm.sh --clone` 改主机名、IP、写 hosts：容器的 IP、主机名和 /etc/hosts 由 Docker 指定，没有在这次验证里执行；教程 5.1 的 `ip -br addr`、`getent hosts` 输出是示意。
- 交互式安装：MySQL 官方包在交互安装时会弹 debconf 对话框问 root 密码，验证用的是 `DEBIAN_FRONTEND=noninteractive`，教程里按“留空回车”写，效果相同（root 用 auth_socket）。

容器环境的差异（真实虚拟机上不需要）：基础镜像里有 Docker 的 `/usr/sbin/policy-rc.d`，会阻止装包后自动启动服务，验证时删掉了；chrony 加了 `-x`（不调宿主机时钟）；时区手工设成 Asia/Shanghai。
