# SRE-5 基础设施即代码 Terraform

对应教程：《DevOps 运维实战》进阶 SRE-5 基础设施即代码 Terraform

写作时版本：Terraform 1.17.2，OpenTofu 1.13.10，阿里云 provider `aliyun/alicloud` 2.3.0，random 3.9.1，local 2.9.1。ECS 系统镜像 Ubuntu 24.04（`name_regex = "^ubuntu_24_04_x64_20G_alibase_"`，写作时最新 `ubuntu_24_04_x64_20G_alibase_20261016.vhd`）。以官方最新文档为准。

**费用提醒：`alicloud/` 下的代码会创建按量付费的 ECS 和公网流量，实验完必须 `terraform destroy`，再用 `scripts/check-leftover.sh` 和控制台确认。**

## 文件

| 路径 | 用途 |
|---|---|
| `local-practice/` | 离线练习版：只用 random / local provider，不需要云账号、不花钱。练 plan / apply / destroy、模块、state、workspace，生成本地虚拟机的 Ansible inventory |
| `alicloud/modules/network/` | 网络模块：VPC、交换机、安全组、安全组规则 |
| `alicloud/modules/ecs/` | ECS 模块：按 map 创建按量付费服务器 |
| `alicloud/templates/inventory.tftpl` | Ansible inventory 模板 |
| `alicloud/envs/dev/` | dev 环境（3 台：lab-web1、lab-web2、lab-db1） |
| `alicloud/envs/staging/` | staging 环境（2 台），演示“按目录分环境” |
| `alicloud/envs/*/backend.tf.example` `backend.hcl.example` | 远程 state（OSS + 表格存储锁）配置示例 |
| `alicloud/bootstrap-state/` | 创建存 state 的 OSS bucket 和加锁用的表格存储表 |
| `ansible/bootstrap.yml` | Terraform 建好机器后由 Ansible 做系统初始化 |
| `ci/.gitlab-ci.yml` | 变更流水线：MR 里 fmt / validate / 扫描 / plan，合并后手动 apply |
| `scripts/check-leftover.sh` | destroy 后检查残留资源 |
| `.gitignore` | 不能提交的文件：state、tfvars、backend.hcl、生成的 inventory |

## 快速开始（离线练习）

```bash
cd local-practice
terraform init
terraform plan
terraform apply
cat inventory-default.ini
terraform destroy
```

## 快速开始（阿里云）

```bash
export ALIBABA_CLOUD_ACCESS_KEY_ID=...        # 专门给实验建的 RAM 用户
export ALIBABA_CLOUD_ACCESS_KEY_SECRET=...
cd alicloud/envs/dev
cp terraform.tfvars.example terraform.tfvars   # 改 admin_cidr
terraform init
terraform plan -out=tfplan
terraform apply tfplan
ansible -i inventory.ini all -m ping
terraform destroy                              # 用完马上删
bash ../../../scripts/check-leftover.sh .
```

## 验证记录

在 Ubuntu 24.04 容器里真跑通过（Terraform 用 HashiCorp 官方 APT 源、OpenTofu 用官方 APT 源安装，都写成 DEB822）：

- `local-practice`：Terraform 1.17.2 和 OpenTofu 1.13.10 各跑一遍 init / validate / plan（8 to add）/ apply / state list / `output -raw` / 改 lab-db1 IP 的 plan（3 to add, 3 to destroy）/ workspace new staging + apply / destroy（两次 8 destroyed）/ workspace delete，结果和教程一致
- `local-practice/.terraform.lock.hcl`：Terraform 在 linux_amd64 上 init 时补了两条 `h1:` 哈希，已提交更新后的 lock 文件；OpenTofu 会把 lock 改写成 `registry.opentofu.org`，不要提交 OpenTofu 生成的 lock
- `terraform init -backend=false && terraform validate && terraform fmt -check -recursive`：`alicloud/bootstrap-state`、`alicloud/envs/dev`、`alicloud/envs/staging` 全部通过（provider 2.3.0 实际下载），确认 `alicloud_images` 的 `owners`、`name_regex`、`architecture`、`most_recent` 参数在 2.3.0 里有效
- `ansible/bootstrap.yml`（已从 dnf / chronyd 改成 apt / chrony）：用 Ubuntu 24.04 自带源的 ansible-core 2.16.3 对一台 Ubuntu 24.04 容器执行。等 SSH、收集信息、主机名、装工具、chrony 启动（systemd-timesyncd 被自动卸掉）、时区 Asia/Shanghai 都成功；写 `/etc/hosts` 那一步在容器里失败（Docker 把 `/etc/hosts` 绑定挂载进容器，不能整体替换，报 `Device or resource busy`），这是容器环境的限制，云服务器上不存在，没有在真实虚拟机上补测
- `scripts/check-leftover.sh`：`shellcheck` + `bash -n` 通过

没有验证：

- `alicloud/` 的 plan / apply / destroy：需要真实阿里云账号，按要求不对任何云账号执行。`name_regex` 是对照阿里云帮助中心的“Ubuntu 镜像发布记录”写的，没有用 API 实际查询
- `ci/.gitlab-ci.yml`：需要 GitLab Runner，只做了 YAML 语法检查
