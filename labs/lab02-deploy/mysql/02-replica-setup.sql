-- lab-db2（从库）执行：sudo mysql < 02-replica-setup.sql
-- 前提：主库和从库都是新装的、开了 GTID，主库的 binlog 从第一条事务开始都在（没被清理），
--       这样从库从零开始把主库的所有事务（建库、导数据、建账号）重放一遍，不用先导全量数据。
--       主库已经跑了很久、binlog 被清理过的情况，要先用 mysqldump / XtraBackup 做一份全量再接复制，见教程 7. 常见的坑。
-- 对应教程：Lab 02 商城上线 5.4 节

-- 清掉从库自己产生的 GTID（装包初始化、手工执行过的写操作会在从库上生成本机 UUID 的事务），
-- 否则从库带着“主库没有的事务”（errant transaction），以后主从切换会出问题
-- MySQL 8.4 已删除 RESET MASTER，用新语法
RESET BINARY LOGS AND GTIDS;

-- MySQL 8.4 已删除 CHANGE MASTER TO / START SLAVE，只能用新语法
-- SOURCE_AUTO_POSITION=1：按 GTID 自动定位，不用手工找 binlog 文件名和位置
-- GET_SOURCE_PUBLIC_KEY=1：repl 用默认的 caching_sha2_password 插件、又没开 TLS 时必须加，否则 IO 线程连不上
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='192.168.56.13',
  SOURCE_PORT=3306,
  SOURCE_USER='repl',
  SOURCE_PASSWORD='ChangeMe-Repl-123',
  SOURCE_AUTO_POSITION=1,
  GET_SOURCE_PUBLIC_KEY=1;

START REPLICA;
