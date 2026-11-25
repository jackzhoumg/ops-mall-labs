---
title: MySQL 主从延迟排查
tags: mysql, replication, 主从延迟, lab-db2
owner: DBA 组
updated: 2026-09-20
---
# MySQL 主从延迟排查

## 1. 现象
- 告警 `MysqlReplicationLag`：从库 lab-db2（192.168.56.14）延迟超过 30 秒。
- 业务反馈：刚下的订单，在"我的订单"里查不到（读请求走了从库）。

## 2. 确认延迟
在 lab-db2 上执行：
```bash
mysql -uroot -p -e 'SHOW REPLICA STATUS\G' | grep -E 'Replica_IO_Running|Replica_SQL_Running|Seconds_Behind_Source|Last_.*Error|Retrieved_Gtid_Set|Executed_Gtid_Set'
```
- `Replica_IO_Running: Yes` 且 `Replica_SQL_Running: Yes`：复制在跑，只是慢。
- 任何一个是 `No`：复制已经断了，延迟数值没有意义，看 `Last_IO_Error` / `Last_SQL_Error`，转第 4 节。
- `Seconds_Behind_Source` 只是估算值，网络断开时会显示 NULL。更准的方法是在主库写心跳表，从库对比时间（pt-heartbeat 的做法）。

## 3. 复制在跑但很慢，常见原因
1. **主库有大事务**：一次删除或更新几十万行，从库要单线程回放很久。在主库查：
   ```bash
   mysql -uroot -p -e "SELECT trx_id, trx_started, trx_rows_modified FROM information_schema.innodb_trx ORDER BY trx_started LIMIT 5;"
   ```
   处理：大批量操作拆成每批 1000-5000 行，批次之间 sleep。
2. **从库回放是单线程**：MySQL 8.0 起用多线程回放，检查：
   ```bash
   mysql -uroot -p -e "SHOW VARIABLES LIKE 'replica_parallel%';"
   ```
   建议 `replica_parallel_workers=4`、`replica_preserve_commit_order=ON`。
3. **从库机器资源不够**：`iostat -x 1 5` 看磁盘 util 是否接近 100%，`top` 看 CPU。从库上跑报表、备份（mysqldump）也会抢资源。
4. **表没有主键**：row 格式回放时没主键要全表扫描，延迟会急剧上升。查没有主键的表：
   ```sql
   SELECT t.table_schema, t.table_name FROM information_schema.tables t
   LEFT JOIN information_schema.table_constraints c
     ON t.table_schema = c.table_schema AND t.table_name = c.table_name AND c.constraint_type = 'PRIMARY KEY'
   WHERE t.table_schema = 'mall' AND c.constraint_name IS NULL;
   ```

## 4. 复制断了
- `Last_SQL_Error` 是 `1062 Duplicate entry`：从库被人直接写过数据。**不要**随手 `SET GLOBAL sql_replica_skip_counter`，跳过事务会让主从数据不一致。先确认那一行在主从上的差异，报 DBA 处理。
- `Last_IO_Error` 提示找不到 binlog：主库 binlog 已被清理（`binlog_expire_logs_seconds` 太短），只能用备份重建从库。

## 5. 业务侧止血
- 延迟持续超过 5 分钟：把读流量切回主库（应用配置或 ProxySQL 规则），等从库追上再切回。
- 订单详情这类"写后马上读"的场景，应用层固定读主库。

## 6. 预防
- 监控 `mysql_slave_status_seconds_behind_master` 和复制线程状态两类指标，线程状态告警优先级更高。
- binlog 保留至少 7 天，`binlog_expire_logs_seconds=604800`。
