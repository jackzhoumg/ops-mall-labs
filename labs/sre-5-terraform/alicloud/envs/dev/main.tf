locals {
  name_prefix = "ops-mall-${var.env}"
  tags = {
    project    = "ops-mall-lab"
    env        = var.env
    managed_by = "terraform"
  }
}

# ---------- 查询类数据（data source 只读，不创建资源，不花钱） ----------

data "alicloud_zones" "available" {
  available_resource_creation = "VSwitch"
  available_disk_category     = "cloud_essd"
}

locals {
  zone_id = var.zone_id != "" ? var.zone_id : data.alicloud_zones.available.zones[0].id
}

data "alicloud_instance_types" "candidate" {
  availability_zone    = local.zone_id
  cpu_core_count       = var.instance_cpu
  memory_size          = var.instance_memory
  instance_charge_type = "PostPaid"
}

data "alicloud_images" "rocky9" {
  owners       = "system"
  name_regex   = "^rockylinux_9"
  architecture = "x86_64"
  most_recent  = true
}

locals {
  instance_type = var.instance_type != "" ? var.instance_type : data.alicloud_instance_types.candidate.instance_types[0].id
}

# ---------- 资源 ----------

resource "alicloud_ecs_key_pair" "lab" {
  key_pair_name = "${local.name_prefix}-key"
  public_key    = file(pathexpand(var.ssh_public_key_path))
  tags          = local.tags
}

module "network" {
  source = "../../modules/network"

  name_prefix = local.name_prefix
  zone_id     = local.zone_id
  admin_cidr  = var.admin_cidr
  tags        = local.tags
}

module "ecs" {
  source = "../../modules/ecs"

  name_prefix       = local.name_prefix
  instances         = var.instances
  zone_id           = local.zone_id
  vswitch_id        = module.network.vswitch_id
  security_group_id = module.network.security_group_id
  instance_type     = local.instance_type
  image_id          = data.alicloud_images.rocky9.images[0].id
  key_pair_name     = alicloud_ecs_key_pair.lab.key_pair_name
  tags              = local.tags
}

# ---------- 生成 Ansible inventory ----------

locals {
  servers = module.ecs.servers
  # 分组 => 主机名列表，例如 { web = ["lab-web1","lab-web2"], db = ["lab-db1"] }
  ansible_groups = {
    for g in distinct(flatten([for s in values(local.servers) : s.groups])) :
    g => sort([for name, s in local.servers : name if contains(s.groups, g)])
  }
}

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/inventory.ini"
  file_permission = "0644"
  content = templatefile("${path.module}/../../templates/inventory.tftpl", {
    env     = var.env
    ssh_key = pathexpand(var.ssh_private_key_path)
    servers = local.servers
    groups  = local.ansible_groups
  })
}
