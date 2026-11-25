output "vpc_id" {
  description = "VPC ID"
  value       = alicloud_vpc.this.id
}

output "vswitch_id" {
  description = "交换机 ID"
  value       = alicloud_vswitch.this.id
}

output "security_group_id" {
  description = "安全组 ID"
  value       = alicloud_security_group.this.id
}
