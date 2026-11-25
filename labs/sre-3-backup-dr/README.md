# SRE-3 备份容灾与高可用演练

对应教程：《DevOps 运维实战》进阶-SRE / SRE-3-备份容灾与高可用演练。

## 文件

| 文件 | 用途 | 在哪执行 |
|---|---|---|
| `minio/install-minio.sh` | 从源码编译并安装单机 MinIO（systemd），备份专用对象存储 | lab-dev |
| `minio/minio.service` | MinIO 的 systemd 单元 | lab-dev |
| `minio/policy-velero.json` `minio/policy-mysql-backup.json` | MinIO 最小权限策略：Velero 只能读写 velero 桶；数据库备份账号只能写 mysql-backup 桶、不能删除 | lab-dev |
| `minio/rclone.conf.example` | rclone 连接 MinIO 的配置 | lab-db1、lab-dev |
| `velero/install-velero.sh` | 安装 Velero 服务端，备份位置指向 MinIO | k8s-master |
| `velero/credentials-velero.example` | Velero 访问 MinIO 的密钥文件模板（复制成 `credentials-velero`，已在 .gitignore） | k8s-master |
| `velero/schedule-mall.yaml` | 定时备份：mall 每天、整个集群每周 | k8s-master |
| `mysql/binlog-settings.cnf` | PITR 对 MySQL 的配置要求（binlog、GTID、双 1） | lab-db1、lab-db2 |
| `mysql/backup-user.sql` | 备份专用账号（最小权限） | lab-db1 |
| `mysql/backup.env.example` `mysql/backup-my.cnf.example` | 备份脚本配置、备份账号连接配置 | lab-db1 |
| `mysql/mysql-full-backup.sh` | 每日全备：mysqldump 一致性快照 → 压缩 → 校验 → 上传 MinIO → 写监控指标 | lab-db1 |
| `mysql/mysql-binlog-upload.sh` | 每 5 分钟上传已关闭的 binlog（RPO 约 5 分钟） | lab-db1 |
| `mysql/systemd/*` | 上面两个脚本的 systemd service + timer | lab-db1 |
| `mysql/find-binlog-event.sh` | 在 binlog 里找误操作，输出位置、时间、GTID | lab-dev / lab-db1 |
| `mysql/mysql-pitr-restore.sh` | 时间点恢复：下载全备和 binlog，在临时 MySQL（Docker）里恢复到误操作之前，或者只跳过误操作那个事务 | lab-dev |
| `mysql/failover/check-replication.sh` | 查看本机角色、复制状态，对比两边 GTID | lab-db1、lab-db2 |
| `mysql/failover/promote-replica.sh` | 手动切换：等 relay log 执行完 → 断开复制 → 关闭只读 | lab-db2 |
| `mysql/failover/rejoin-as-replica.sh` | 旧主库修好后检查多余事务，再以从库身份加入 | lab-db1 |
| `k8s/mysql-endpointslice-db2.yaml` `k8s/mysql-endpointslice-db1.yaml` | 把 K8s 里 `mysql` Service 的后端切到 lab-db2 / 切回 lab-db1（和 Lab 08 Chart 的 `mysql-external` 同名） | k8s-master |
| `monitoring/backup-alerts.yaml` | 备份监控告警：全备过期 / 失败、binlog 上传中断、Velero 备份过期 / 失败 | k8s-master |
| `monitoring/node-exporter-textfile.conf` | 给 Lab 09 的 node_exporter 打开 textfile collector，读取备份指标 | lab-db1 |
| `monitoring/velero-podmonitor.yaml` | 抓取 Velero 指标 | k8s-master |
| `scripts/probe-availability.sh` | 演练秒表：每秒探测读写接口，结束后输出中断时长（实测 RTO） | 学员电脑 |
| `drill/business-tiering-template.md` | 业务分级与 RTO / RPO 目标模板 | |
| `drill/dr-drill-plan-template.md` | 容灾演练方案模板 | |
| `drill/dr-drill-report-template.md` | 容灾演练报告模板 | |

## 校验

```bash
shellcheck minio/*.sh velero/*.sh mysql/*.sh mysql/failover/*.sh scripts/*.sh
for f in minio/*.json; do python3 -m json.tool "$f" >/dev/null && echo "ok $f"; done
```

## 写作时版本

Velero v1.19.0（官方测试过 Kubernetes 1.36.5）、velero-plugin-for-aws v1.15.0、MinIO 社区版 RELEASE.2025-10-15T17-29-55Z（最后一个发布版本，仓库已标注不再维护）、rclone v1.76.0、MySQL 8.4 LTS。以各项目官方文档为准。
