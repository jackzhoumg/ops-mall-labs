# SRE-3 备份容灾与高可用演练

对应教程：《DevOps 运维实战》进阶-SRE / SRE-3-备份容灾与高可用演练。

## 文件

| 文件 | 用途 | 在哪执行 |
|---|---|---|
| `seaweedfs/install-seaweedfs.sh` | 下载官方二进制，安装单机 SeaweedFS（`weed mini`，systemd），生成账号配置，ufw 只放行 S3 端口 | lab-dev |
| `seaweedfs/seaweedfs.service` | SeaweedFS 的 systemd 单元（只开 S3 网关需要的组件） | lab-dev |
| `seaweedfs/policy-velero.json` `seaweedfs/policy-mysql-backup.json` | 账号的 IAM 策略：Velero 只能读写删 velero 桶；数据库备份账号只能读写 mysql-backup 桶、不能删除 | lab-dev |
| `seaweedfs/rclone.conf.example` | rclone 连接 SeaweedFS S3 网关的配置（远端名 `s3backup`） | lab-db1、lab-dev |
| `velero/install-velero.sh` | 安装 Velero 服务端，备份位置指向 SeaweedFS | k8s-master |
| `velero/credentials-velero.example` | Velero 访问对象存储的密钥文件模板（复制成 `credentials-velero`，已在 .gitignore） | k8s-master |
| `velero/schedule-mall.yaml` | 定时备份：mall 每天、整个集群每周 | k8s-master |
| `mysql/binlog-settings.cnf` | PITR 对 MySQL 的配置要求（binlog、GTID、双 1） | lab-db1、lab-db2 |
| `mysql/backup-user.sql` | 备份专用账号（最小权限） | lab-db1 |
| `mysql/backup.env.example` `mysql/backup-my.cnf.example` | 备份脚本配置、备份账号连接配置 | lab-db1 |
| `mysql/mysql-full-backup.sh` | 每日全备：mysqldump 一致性快照 → 压缩 → 校验 → 上传对象存储 → 写监控指标 | lab-db1 |
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
shellcheck seaweedfs/*.sh velero/*.sh mysql/*.sh mysql/failover/*.sh scripts/*.sh
for f in seaweedfs/*.json; do python3 -m json.tool "$f" >/dev/null && echo "ok $f"; done
```

## 写作时版本

Velero v1.19.0（官方测试过 Kubernetes 1.36.5 和 1.37.1）、velero-plugin-for-aws v1.15.0、SeaweedFS 4.55、rclone v1.76.0（官方 deb 包）、s3cmd（Ubuntu 24.04 自带源）、MySQL 8.4 LTS（MySQL 官方 APT 源，实测 8.4.13）。以各项目官方文档为准。

为什么从 MinIO 换成 SeaweedFS：MinIO 社区版 2025 年起只发源码、GitHub 仓库已归档，不再修漏洞；SeaweedFS 是 Apache-2.0、每周发版，有官方 amd64 / arm64 二进制，支持按账号绑定 IAM 策略（备份账号能写不能删）、版本控制、对象锁定和生命周期。Garage 也在维护，但不支持版本控制和对象锁定，写权限包含删除，满足不了“备份账号不能删”。

## 验证记录

验证环境：Ubuntu 24.04 容器（带 systemd），4 个容器分别扮演 lab-db1、lab-db2、lab-dev、lab-web1，网段和教程不同（输出里的 IP 已按教程规划改写）。

已在 Ubuntu 24.04 上真跑通过：

- `seaweedfs/install-seaweedfs.sh`：SeaweedFS 4.55 安装、systemd 启动、ufw 放行 8333；三个账号的权限实测：备份账号能写能读、删除返回 AccessDenied、看不到 velero 桶；Velero 账号能读写删 velero 桶、访问 mysql-backup 返回 AccessDenied。`s3cmd expire` 设置 14 天生命周期规则成功（是否按时过期没有等 14 天验证）
- MySQL 8.4.13（官方 APT 源 `mysql-8.4-lts`）一主一从、GTID 复制；`binlog-settings.cnf` 放 `/etc/mysql/mysql.conf.d/`
- `mysql-full-backup.sh`、`mysql-binlog-upload.sh`、两个 systemd 定时器、textfile 指标文件
- `find-binlog-event.sh` 找到 `DROP TABLE` 的位置和 GTID
- `mysql-pitr-restore.sh`：`EXCLUDE_GTIDS` 和 `STOP_DATETIME` 两种方式都恢复正确，导回主库后复制正常。验证中发现 `mysql:8.4` 镜像（8.4.13）里已经没有 `mysqlbinlog`，脚本已改成镜像里没有就用本机的（本机装 `mysql-community-server-core`）
- `failover/check-replication.sh`、`promote-replica.sh`、`rejoin-as-replica.sh`：主库停机 → 提升从库 → 旧主库发现 errant transaction 并停下 → 修平后重新加入复制。修了一个显示问题：`gtid_executed` 有多段时 `mysql -B` 会输出字面量 `\n`
- 所有脚本 `shellcheck` + `bash -n` 通过

没有验证的部分及原因：

- Velero 安装、备份恢复、`velero/schedule-mall.yaml`、`k8s/`、`monitoring/*.yaml`：需要 K8s 集群，按要求不连集群，只做了 YAML 语法检查；`monitoring/backup-alerts.yaml` 里的规则用 promtool v3.16.0 `check rules` 通过
- node_exporter textfile drop-in（`monitoring/node-exporter-textfile.conf`）：验证环境没装 Lab 09 的 node_exporter，只确认了指标文件内容
- `scripts/probe-availability.sh`：依赖 K8s 里的 mall-api 和网关，没有跑
- 计划内回切（5.6 第 8 步）、切换后在 lab-db2 上迁移备份任务：步骤和已验证的部分相同，没有单独跑
- scp 传文件那一步用的是容器间拷贝
