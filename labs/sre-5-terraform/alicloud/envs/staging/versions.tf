terraform {
  # 写作时 Terraform 最新版 1.17.2；alicloud provider 最新版 2.3.0。以官方最新文档为准。
  required_version = ">= 1.10.0"

  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 2.3"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }
}

# 凭据不写在代码里。执行前在终端里设置环境变量：
#   export ALIBABA_CLOUD_ACCESS_KEY_ID=...
#   export ALIBABA_CLOUD_ACCESS_KEY_SECRET=...
provider "alicloud" {
  region = var.region
}
