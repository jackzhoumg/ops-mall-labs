output "servers" {
  description = "主机名 => 模拟的实例 ID、公网 IP 和真实内网 IP"
  value       = local.servers
}

output "ansible_inventory" {
  description = "生成的 inventory 文件"
  value       = local_file.ansible_inventory.filename
}

output "mysql_password" {
  description = "演示 sensitive：plan/apply 时显示为 (sensitive value)，用 terraform output -raw mysql_password 才能看到"
  value       = random_password.mysql.result
  sensitive   = true
}
