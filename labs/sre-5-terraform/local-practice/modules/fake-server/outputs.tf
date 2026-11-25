output "servers" {
  description = "主机名 => 实例信息"
  value = {
    for name, cfg in var.instances : name => {
      instance_id = random_id.instance[name].hex
      public_ip   = "203.0.113.${random_integer.public_ip_octet[name].result}"
      private_ip  = cfg.private_ip
      groups      = cfg.groups
    }
  }
}
