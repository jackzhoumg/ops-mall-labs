# 网络模块：一个 VPC、一个交换机、一个安全组和几条入方向规则。

resource "alicloud_vpc" "this" {
  vpc_name   = "${var.name_prefix}-vpc"
  cidr_block = var.vpc_cidr
  tags       = var.tags
}

resource "alicloud_vswitch" "this" {
  vswitch_name = "${var.name_prefix}-vsw"
  vpc_id       = alicloud_vpc.this.id
  cidr_block   = var.vswitch_cidr
  zone_id      = var.zone_id
  tags         = var.tags
}

resource "alicloud_security_group" "this" {
  security_group_name = "${var.name_prefix}-sg"
  vpc_id              = alicloud_vpc.this.id
  description         = "ops-mall lab, managed by terraform"
  tags                = var.tags
}

# 从管理员 IP 放行 SSH / HTTP / HTTPS。每个端口一条规则，for_each 用端口号做键，
# 增删端口时只影响对应那一条，不会让其他规则重建。
resource "alicloud_security_group_rule" "admin_ingress" {
  for_each = toset([for p in var.ingress_ports : tostring(p)])

  security_group_id = alicloud_security_group.this.id
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "${each.value}/${each.value}"
  priority          = 1
  cidr_ip           = var.admin_cidr
  description       = "admin tcp ${each.value}"
}

# VPC 内部机器之间全部互通（MySQL 主从、Nginx 到 mall-api 都走内网）。
resource "alicloud_security_group_rule" "vpc_internal" {
  security_group_id = alicloud_security_group.this.id
  type              = "ingress"
  ip_protocol       = "all"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  cidr_ip           = var.vpc_cidr
  description       = "vpc internal"
}
