output "zone_id" {
  description = "实际使用的可用区"
  value       = local.zone_id
}

output "instance_type" {
  description = "实际使用的实例规格，apply 前去控制台核对单价"
  value       = local.instance_type
}

output "image" {
  description = "使用的系统镜像"
  value       = data.alicloud_images.ubuntu2404.images[0].name
}

output "servers" {
  description = "主机名 => 公网 / 内网 IP"
  value       = module.ecs.servers
}

output "ssh_commands" {
  description = "直接复制就能登录"
  value       = { for name, s in module.ecs.servers : name => "ssh -i ${var.ssh_private_key_path} root@${s.public_ip}" }
}

output "ansible_inventory" {
  description = "生成的 Ansible inventory 文件"
  value       = local_file.ansible_inventory.filename
}
