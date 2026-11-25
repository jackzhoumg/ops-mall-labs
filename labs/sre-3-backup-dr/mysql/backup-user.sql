-- 备份专用账号：只能从本机连接，只给备份需要的权限（最小权限）。
-- 用法（lab-db1，root 执行）：mysql < mysql/backup-user.sql
-- 密码换成强密码，并同步改 /etc/mall-backup/my.cnf。

CREATE USER IF NOT EXISTS 'backup'@'localhost' IDENTIFIED BY 'ChangeMe-Backup-123';

-- mysqldump --single-transaction 需要：SELECT、SHOW VIEW、TRIGGER、EVENT、LOCK TABLES
-- --flush-logs / 获取一致性位点需要：RELOAD、REPLICATION CLIENT、BACKUP_ADMIN
-- 上传 binlog 前 FLUSH BINARY LOGS 需要：RELOAD
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, RELOAD, REPLICATION CLIENT ON *.* TO 'backup'@'localhost';
GRANT BACKUP_ADMIN ON *.* TO 'backup'@'localhost';
