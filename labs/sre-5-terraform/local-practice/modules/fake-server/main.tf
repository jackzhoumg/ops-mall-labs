# 用 random 资源模拟“创建一台云服务器”：
#   random_id      ≈ 云厂商返回的实例 ID
#   random_integer ≈ 云厂商分配的公网 IP（用 203.0.113.0/24 文档保留网段，不是真实地址）
# keepers 变化时资源会被替换，相当于“改了不能原地修改的属性，机器要重建”。

resource "random_id" "instance" {
  for_each = var.instances

  byte_length = 8
  prefix      = "i-"
  keepers = {
    env        = var.env
    private_ip = each.value.private_ip
  }
}

resource "random_integer" "public_ip_octet" {
  for_each = var.instances

  min = 1
  max = 254
  keepers = {
    instance_id = random_id.instance[each.key].hex
  }
}
