terraform {
  required_version = ">= 1.10.0"

  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 2.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

provider "alicloud" {
  region = var.region
}
