variable "env" {
  description = "环境名，会出现在资源名和标签里"
  type        = string
  default     = "staging"
}

variable "region" {
  description = "地域"
  type        = string
  default     = "cn-hangzhou"
}

variable "zone_id" {
  description = "可用区。留空则自动选第一个能建 ESSD 云盘和 VSwitch 的可用区"
  type        = string
  default     = ""
}

variable "admin_cidr" {
  description = "你自己的公网 IP/32"
  type        = string
}

variable "ssh_public_key_path" {
  description = "SSH 公钥路径，会上传成 ECS 密钥对"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "SSH 私钥路径，只写进 Ansible inventory，不会上传"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "instance_type" {
  description = "实例规格。留空则按 cpu/memory 自动挑一个，挑出来的规格会显示在 plan 里，看清单价再 apply"
  type        = string
  default     = ""
}

variable "instance_cpu" {
  description = "自动挑规格时的 vCPU 数"
  type        = number
  default     = 2
}

variable "instance_memory" {
  description = "自动挑规格时的内存（GB）"
  type        = number
  default     = 4
}

variable "instances" {
  description = "主机名 => 内网 IP 和 Ansible 分组"
  type = map(object({
    private_ip = string
    groups     = list(string)
  }))
  default = {
    "stg-web1" = { private_ip = "172.16.1.11", groups = ["web"] }
    "stg-db1"  = { private_ip = "172.16.1.13", groups = ["db"] }
  }
}
