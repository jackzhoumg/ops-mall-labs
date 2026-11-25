# SRE-5 基础设施即代码 Terraform

对应教程：《DevOps 运维实战》进阶 SRE-5 基础设施即代码 Terraform

写作时版本：Terraform 1.17.2，阿里云 provider `aliyun/alicloud` 2.3.0，random 3.9.1，local 2.9.1。以官方最新文档为准。

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

- `terraform fmt -check -recursive`：通过
- `terraform init -backend=false && terraform validate`：`alicloud/envs/dev`、`alicloud/envs/staging`、`alicloud/bootstrap-state`、`local-practice` 全部通过（alicloud provider 2.3.0）
- `local-practice`：在本机完成 init / plan / apply / workspace / destroy 全流程
- `alicloud/`：没有执行 plan / apply（需要真实账号），由讲师在真实账号上验证
