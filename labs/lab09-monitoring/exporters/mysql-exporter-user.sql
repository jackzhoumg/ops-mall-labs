-- Lab 09：mysqld_exporter 用的只读监控账号
-- 在 lab-db1（主库）执行：mysql -uroot -p < mysql-exporter-user.sql
-- CREATE USER 会写进 binlog 同步到 lab-db2，从库上不用再建。
-- 执行前把密码换掉，和 install-exporters.sh 的 MYSQL_EXPORTER_PASSWORD 保持一致。
--
-- 只允许本机连接（exporter 和 MySQL 在同一台机器上），MAX_USER_CONNECTIONS 防止 exporter 出问题时占满连接。
CREATE USER IF NOT EXISTS 'exporter'@'127.0.0.1' IDENTIFIED BY 'ExporterPass123' WITH MAX_USER_CONNECTIONS 3;
-- PROCESS：读 processlist 和 InnoDB 状态；REPLICATION CLIENT：读主从复制状态；
-- SELECT：读 performance_schema / information_schema 里的统计表。都不能改数据。
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'127.0.0.1';
FLUSH PRIVILEGES;
