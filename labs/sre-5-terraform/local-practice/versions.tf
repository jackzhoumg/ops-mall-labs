terraform {
  required_version = ">= 1.10.0"

  # 只用 random 和 local 两个 provider：不连任何云，不需要账号，不花钱。
  # 写作时版本：random 3.9.1，local 2.9.1。
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }
}
