variable "instances" {
  description = "主机名 => 内网 IP 和 Ansible 分组。默认就是课程约定的本地虚拟机"
  type = map(object({
    private_ip = string
    groups     = list(string)
  }))
  default = {
    "lab-web1" = { private_ip = "192.168.56.11", groups = ["web"] }
    "lab-web2" = { private_ip = "192.168.56.12", groups = ["web"] }
    "lab-db1"  = { private_ip = "192.168.56.13", groups = ["db"] }
  }

  validation {
    condition     = alltrue([for s in values(var.instances) : can(cidrnetmask("${s.private_ip}/32"))])
    error_message = "private_ip 必须是合法的 IPv4 地址。"
  }
}

variable "ansible_user" {
  description = "Ansible 登录用户，本地虚拟机用 ops"
  type        = string
  default     = "ops"
}

variable "ssh_private_key_path" {
  description = "SSH 私钥路径"
  type        = string
  default     = "~/.ssh/id_ed25519"
}
