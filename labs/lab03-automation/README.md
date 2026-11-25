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
| `ansible/roles/common` | 主机名、hosts、时区、基础包、firewalld、内核参数、巡检脚本和定时任务 |
| `ansible/roles/mysql` | MySQL 8.4 安装、初始化、主库导入 `sql/init.sql`、建账号、从库 GTID 复制、从库定时备份 |
| `ansible/roles/redis` | Redis 安装、密码、内存上限、持久化 |
| `ansible/roles/mall_api` | mall-api 二进制、环境变量文件、systemd 服务，部署后等 `/readyz` 通过 |
| `ansible/roles/nginx` | Nginx、自签证书、静态页面、`/api/` 反代到两台 mall-api、SELinux 布尔值 |
| `ansible/roles/keepalived` | Keepalived 单播 VRRP，VIP 192.168.56.10 |
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

- 角色按 Rocky Linux 9 编写，`common` 角色第一步会检查系统版本。
- ansible.mysql、ansible.posix 新版要求 ansible-core 2.16 以上。Rocky 9 软件源里的 `ansible-core` 版本偏旧，建议用 pip 装到虚拟环境。
- `keepalived_interface`（默认 `enp0s8`）按自己虚拟机的网卡名改，在 `group_vars/web.yml`。
- 自签证书在控制节点生成到 `ansible/files/certs/`，私钥已被 `.gitignore` 忽略，不要提交。
