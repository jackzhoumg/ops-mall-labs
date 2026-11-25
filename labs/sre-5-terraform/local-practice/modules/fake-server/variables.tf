variable "env" {
  description = "环境名"
  type        = string
}

variable "instances" {
  description = "主机名 => 内网 IP 和分组"
  type = map(object({
    private_ip = string
    groups     = list(string)
  }))
}
