# Lab 02 商城上线：Nginx + MySQL + Redis

对应教程：《DevOps 运维实战》Lab 02 商城上线：Nginx + MySQL + Redis。

这里的配置是手工部署用的“最终版”，路径、文件名、账号和 Lab 03 的 Ansible 角色（`labs/lab03-automation/ansible/`）一致。Lab 03 用 Ansible 重放这一课时，生成的配置和这里一样。

| 文件 | 放到哪台机器、哪个路径 | 用途 |
|---|---|---|
| `mysql/mysql84-community.repo` | lab-db1、lab-db2：`/etc/yum.repos.d/` | MySQL 8.4 LTS 官方源（清华镜像） |
| `mysql/my-primary.cnf` | lab-db1：`/etc/my.cnf` | 主库配置：server-id=1、binlog、GTID、慢日志 |
| `mysql/my-replica.cnf` | lab-db2：`/etc/my.cnf` | 从库配置：server-id=2、relay-log、read_only |
| `mysql/01-primary-accounts.sql` | lab-db1 执行 | 建复制账号 `repl`、备份账号 `backup` |
| `mysql/02-replica-setup.sql` | lab-db2 执行 | GTID 自动定位接上主库 |
| `mysql/mysql-backup.cnf.example` | lab-db1、lab-db2：`/etc/ops/mysql-backup.cnf` | 备份账号密码文件，权限 600 |
| `mysql/mysql_full_backup.sh` | lab-db2：`/usr/local/bin/`，cron 每天 02:30 | mysqldump 全备到 `/data/backup/mysql` |
| `mysql/mysql_pitr.sh` | lab-db1 | 误删恢复：找误操作位置、生成全备 + binlog 回放 SQL（不自动执行） |
| `redis/redis.conf` | lab-db1：`/etc/redis/redis.conf` 里改这几项 | 密码、监听地址、内存上限、AOF |
| `redis/sentinel.conf.example` | 可选练习 | 哨兵关键配置 |
| `certs/gen-cert.sh` | lab-web1 执行一次，证书拷到两台 `/etc/nginx/ssl/` | 自签证书，带 SAN |
| `nginx/mall.conf` | lab-web1、lab-web2：`/etc/nginx/conf.d/mall.conf` | 静态页、`/api/` 反代、upstream、HTTPS、ops 日志格式 |
| `keepalived/keepalived-master.conf` | lab-web1：`/etc/keepalived/keepalived.conf` | VRRP 主，优先级 100 |
| `keepalived/keepalived-backup.conf` | lab-web2：`/etc/keepalived/keepalived.conf` | VRRP 备，优先级 90 |
| `keepalived/check_nginx.sh` | lab-web1、lab-web2：`/usr/libexec/keepalived/` | Nginx 健康检查 |

## 密码

所有密码都是实验默认值，和 Lab 03 `group_vars/all/vault.yml.example` 一致：

| 账号 | 默认密码 |
|---|---|
| MySQL root | `ChangeMe-Root-123` |
| MySQL mall（应用） | `MallPass123`（`sql/init.sql` 里建的） |
| MySQL repl（复制） | `ChangeMe-Repl-123` |
| MySQL backup（备份） | `ChangeMe-Backup-123` |
| Redis | `ChangeMe-Redis-123` |
| Keepalived 认证 | `mall2026` |

改了密码的话，SQL 文件、`mysql-backup.cnf`、`redis.conf`、`/etc/mall-api/mall-api.env` 要一起改，到 Lab 03 再写进 vault。

## 网卡和网段

默认 VirtualBox Host-Only 网段 `192.168.56.0/24`，VIP 网卡 `enp0s8`。VMware、UTM、云服务器不一样，用 `ip -br addr` 查看后替换 IP 和网卡名。

## 检查

```bash
shellcheck certs/gen-cert.sh mysql/*.sh keepalived/check_nginx.sh
bash -n certs/gen-cert.sh mysql/*.sh keepalived/check_nginx.sh
# 在 web 机器上
sudo nginx -t
# 在 web 机器上
sudo keepalived -t -f /etc/keepalived/keepalived.conf
```
