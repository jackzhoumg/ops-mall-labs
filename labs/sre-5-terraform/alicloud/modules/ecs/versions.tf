# 模块里也要声明 provider 来源。不写的话 Terraform 会按 hashicorp/alicloud 去找，init 报错。
terraform {
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = ">= 2.3.0"
    }
  }
}
