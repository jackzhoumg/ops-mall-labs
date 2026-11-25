# 离线练习版：结构和 alicloud/envs/dev 一样（模块 + 输出 + 生成 inventory），
# 只是“服务器”换成了 fake-server 模块，用 random 资源模拟实例 ID 和公网 IP。
# 生成的 inventory 用内网 IP，能直接管理你本机的实验虚拟机。

locals {
  # terraform.workspace 是当前 workspace 名，默认 default。练 workspace 时能看到它变化。
  env = terraform.workspace
}

module "server" {
  source = "./modules/fake-server"

  env       = local.env
  instances = var.instances
}

# 模拟一个数据库密码。注意：sensitive 只是不在屏幕上打印，state 文件里仍然是明文。
resource "random_password" "mysql" {
  length  = 20
  special = false
}

locals {
  servers = module.server.servers
  ansible_groups = {
    for g in distinct(flatten([for s in values(local.servers) : s.groups])) :
    g => sort([for name, s in local.servers : name if contains(s.groups, g)])
  }
}

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/inventory-${local.env}.ini"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/inventory.tftpl", {
    env          = local.env
    ansible_user = var.ansible_user
    ssh_key      = pathexpand(var.ssh_private_key_path)
    servers      = local.servers
    groups       = local.ansible_groups
  })
}
