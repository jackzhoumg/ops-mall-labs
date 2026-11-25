-- Lab 10：打开 MySQL 慢查询日志（lab-db1 执行：mysql -uroot -p < mysql-slow-log.sql）
-- SET PERSIST 立即生效，并写进 mysqld-auto.cnf，重启后仍然有效，不用改 my.cnf、不用重启 MySQL。
-- 超过 1 秒的语句记进慢日志。生产上常见 0.5-2 秒，太小会把日志刷爆。
SET PERSIST slow_query_log_file = '/var/log/mysql/slow.log';
SET PERSIST long_query_time = 1;
SET PERSIST log_slow_admin_statements = ON;
SET PERSIST slow_query_log = ON;
SHOW VARIABLES LIKE 'slow_query%';
