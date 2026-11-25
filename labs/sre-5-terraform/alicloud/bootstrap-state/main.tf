# 远程 state 的“地基”：一个 OSS bucket 存 state 文件，一张表格存储（Tablestore / OTS）的表做锁。
# 这个目录自己的 state 留在本地（鸡生蛋问题：存 state 的桶不能用它自己来存 state）。
# 这个目录建出来的东西要长期保留，实验结束时最后再 destroy。

resource "random_id" "suffix" {
  byte_length = 3
}

resource "alicloud_oss_bucket" "tfstate" {
  bucket = "ops-mall-tfstate-${random_id.suffix.hex}"

  # 实验结束要能一键删干净（开了版本控制的桶里有历史版本，不强制删除会删不掉）。
  # 生产环境必须是 false：state 桶被误删，等于丢了所有基础设施的“账本”。
  force_destroy = true

  # 开版本控制：state 被写坏或误删时可以找回上一个版本
  versioning {
    status = "Enabled"
  }

  server_side_encryption_rule {
    sse_algorithm = "AES256"
  }

  tags = {
    project    = "ops-mall-lab"
    managed_by = "terraform"
  }
}

# state 里有资源的全部属性（可能含密码），bucket 必须私有
resource "alicloud_oss_bucket_acl" "tfstate" {
  bucket = alicloud_oss_bucket.tfstate.bucket
  acl    = "private"
}

resource "alicloud_ots_instance" "lock" {
  name          = "tflock${random_id.suffix.hex}"
  description   = "terraform state lock"
  accessed_by   = "Any"
  instance_type = "Capacity"
  tags = {
    project = "ops-mall-lab"
  }
}

resource "alicloud_ots_table" "lock" {
  instance_name = alicloud_ots_instance.lock.name
  table_name    = "tf_state_lock"
  time_to_live  = -1
  max_version   = 1

  # OSS backend 要求主键名叫 LockID，类型 String
  primary_key {
    name = "LockID"
    type = "String"
  }
}
