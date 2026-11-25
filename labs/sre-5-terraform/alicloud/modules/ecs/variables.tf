variable "name_prefix" {
  description = "资源名前缀"
  type        = string
}

variable "instances" {
  description = <<-EOT
    要创建的服务器。键是主机名，值里写内网 IP 和 Ansible 分组。
    例子：{ "lab-web1" = { private_ip = "172.16.1.11", groups = ["web"] } }
  EOT
  type = map(object({
    private_ip = string
    groups     = list(string)
  }))
}

variable "zone_id" {
  description = "可用区"
  type        = string
}

variable "vswitch_id" {
  description = "交换机 ID"
  type        = string
}

variable "security_group_id" {
  description = "安全组 ID"
  type        = string
}

variable "instance_type" {
  description = "实例规格，例如 ecs.e-c1m2.large。先在控制台确认该可用区有货、看清单价"
  type        = string
}

variable "image_id" {
  description = "镜像 ID"
  type        = string
}

variable "key_pair_name" {
  description = "已创建的 SSH 密钥对名称"
  type        = string
}

variable "internet_max_bandwidth_out" {
  description = "公网带宽上限（Mbps），按流量计费。0 表示不分配公网 IP"
  type        = number
  default     = 5
}

variable "system_disk_size" {
  description = "系统盘大小（GB）"
  type        = number
  default     = 40
}

variable "tags" {
  description = "统一标签"
  type        = map(string)
  default     = {}
}
