output "bucket" {
  description = "填进 backend.hcl 的 bucket"
  value       = alicloud_oss_bucket.tfstate.bucket
}

output "tablestore_endpoint" {
  description = "填进 backend.hcl 的 tablestore_endpoint"
  value       = "https://${alicloud_ots_instance.lock.name}.${var.region}.ots.aliyuncs.com"
}

output "tablestore_table" {
  description = "填进 backend.hcl 的 tablestore_table"
  value       = alicloud_ots_table.lock.table_name
}
