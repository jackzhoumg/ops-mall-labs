---
title: 磁盘写满排查与清理
tags: linux, disk, df, binlog, journald
owner: 运维组
updated: 2026-08-18
---
# 磁盘写满排查与清理

## 1. 现象
- 告警 `HostDiskWillFillIn4Hours` 或 `HostDiskUsageHigh`（使用率超过 90%）。
- MySQL 报 `Errcode: 28 - No space left on device`，下单失败；Nginx 写不了日志；`systemctl` 命令报错。

## 2. 先看是空间满还是 inode 满
```bash
df -hT        # 空间
df -i         # inode：小文件太多时 inode 先用完，df -h 看着还有空间也写不进去
```

## 3. 找出大目录和大文件
```bash
# 按目录逐层往下找，-x 不跨文件系统
sudo du -xh --max-depth=1 / 2>/dev/null | sort -h | tail -15
sudo du -xh --max-depth=1 /var 2>/dev/null | sort -h | tail -15
# 最近一天新增的大文件
sudo find / -xdev -type f -size +500M -mtime -1 -exec ls -lh {} \; 2>/dev/null
```

## 4. 删了文件空间却没释放
文件被进程打开着，删掉后目录里看不到了，但空间要等进程关闭文件才释放。
```bash
sudo lsof +L1 2>/dev/null | head -20     # 列出"已删除但仍被打开"的文件
```
处理：重启对应进程（比如 Nginx `systemctl reload nginx` 会重新打开日志文件）。
以后清日志用 `truncate -s 0 文件` 或 `> 文件`，不要直接 `rm` 正在写的日志。

## 5. 常见占用和安全的清理方法
| 位置 | 原因 | 清理方法 |
|---|---|---|
| `/var/log/journal` | systemd 日志没设上限 | `sudo journalctl --vacuum-size=500M`，并在 `/etc/systemd/journald.conf` 设 `SystemMaxUse=1G` |
| `/var/log/nginx` | logrotate 没生效 | `sudo logrotate -f /etc/logrotate.d/nginx`，检查配置 |
| `/var/lib/mysql/binlog.*` | binlog 保留太久 | 先确认从库已经读到哪个 binlog（`SHOW REPLICA STATUS` 的 `Source_Log_File`），再在主库 `PURGE BINARY LOGS BEFORE NOW() - INTERVAL 3 DAY;`。**不要直接 rm binlog 文件** |
| `/var/lib/containerd`、`/var/lib/docker` | 旧镜像、退出的容器 | K8s 节点：`sudo crictl rmi --prune`；Docker 主机：`docker system prune`（先看清楚会删什么） |
| `/tmp`、家目录 | 有人传了大文件、备份没清 | 确认文件主人后再删 |

## 6. 恢复后检查
```bash
df -h
systemctl --failed
# MySQL 写满过要检查是否正常
mysql -uroot -p -e "SHOW GLOBAL STATUS LIKE 'Uptime'; SHOW REPLICA STATUS\G" | head -20
```

## 7. 预防
- 告警用"预测写满时间"（`predict_linear`），比固定阈值提前发现。
- 日志目录单独分区或单独磁盘，日志写满不影响数据库。
- 所有日志都配 logrotate 或 journald 上限，所有备份脚本都带保留天数。
