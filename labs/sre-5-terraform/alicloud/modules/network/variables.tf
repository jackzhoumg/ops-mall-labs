variable "name_prefix" {
  description = "资源名前缀，例如 ops-mall-dev"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC 网段"
  type        = string
  default     = "172.16.0.0/16"
}

variable "vswitch_cidr" {
  description = "交换机网段，必须在 vpc_cidr 内"
  type        = string
  default     = "172.16.1.0/24"
}

variable "zone_id" {
  description = "交换机所在可用区，例如 cn-hangzhou-i"
  type        = string
}

variable "admin_cidr" {
  description = "允许 SSH 和 HTTP 访问的来源网段，填你自己的公网 IP/32，不要填 0.0.0.0/0"
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr 必须是合法 CIDR，且不能是 0.0.0.0/0。查自己的公网 IP：curl -s https://ifconfig.me"
  }
}

variable "ingress_ports" {
  description = "从 admin_cidr 放行的 TCP 端口"
  type        = list(number)
  default     = [22, 80, 443]
}

variable "tags" {
  description = "统一打在所有资源上的标签"
  type        = map(string)
  default     = {}
}
