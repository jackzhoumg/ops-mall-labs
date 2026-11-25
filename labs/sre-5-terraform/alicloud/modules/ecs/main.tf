# ECS 模块：按 instances 这个 map 创建若干台按量付费的服务器。
# 用 for_each 而不是 count：删掉中间一台时，其他机器不会因为下标变化被重建。

resource "alicloud_instance" "this" {
  for_each = var.instances

  instance_name     = "${var.name_prefix}-${each.key}"
  host_name         = each.key
  availability_zone = var.zone_id
  vswitch_id        = var.vswitch_id
  security_groups   = [var.security_group_id]
  private_ip        = each.value.private_ip

  instance_type = var.instance_type
  image_id      = var.image_id
  key_name      = var.key_pair_name

  # 计费相关，一定看清楚：
  # PostPaid = 按量付费，按秒计费，destroy 之后停止计费。
  # PayByTraffic = 公网按实际流量收费，带宽上限只是封顶值。
  instance_charge_type       = "PostPaid"
  internet_charge_type       = "PayByTraffic"
  internet_max_bandwidth_out = var.internet_max_bandwidth_out

  system_disk_category = "cloud_essd"
  system_disk_size     = var.system_disk_size

  # 实验环境允许 terraform destroy 直接释放；生产环境应该打开删除保护。
  deletion_protection = false

  tags = merge(var.tags, { hostname = each.key })
}
