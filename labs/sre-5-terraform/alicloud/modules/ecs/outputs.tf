output "servers" {
  description = "每台服务器的主机名、公网 IP、内网 IP 和 Ansible 分组"
  value = {
    for name, inst in alicloud_instance.this : name => {
      public_ip  = inst.public_ip
      private_ip = inst.private_ip
      groups     = var.instances[name].groups
    }
  }
}

output "instance_ids" {
  description = "实例 ID"
  value       = { for name, inst in alicloud_instance.this : name => inst.id }
}
