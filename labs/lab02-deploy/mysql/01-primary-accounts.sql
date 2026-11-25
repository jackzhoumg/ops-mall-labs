-- lab-db1（主库）执行：sudo mysql < 01-primary-accounts.sql
-- 前提：已经执行过仓库里的 sql/init.sql（建了 mall 库和 mall 账号）
-- 密码和 Lab 03 group_vars/all/vault.yml.example 的默认值一致；生产环境必须换成强密码
-- 对应教程：Lab 02 商城上线 5.3 节

-- 复制账号：只允许实验网段连接，只给复制权限
CREATE USER IF NOT EXISTS 'repl'@'192.168.56.%' IDENTIFIED BY 'ChangeMe-Repl-123';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'192.168.56.%';

-- 备份账号：只能本机 socket 登录，权限是 mysqldump --single-transaction --source-data 的最小集合
--   RELOAD             --source-data 要短暂执行 FLUSH TABLES WITH READ LOCK
--   REPLICATION CLIENT 读取 binlog 位置（SHOW BINARY LOG STATUS）
--   PROCESS            导出表空间信息
--   EVENT TRIGGER SHOW VIEW  导出事件、触发器、视图
-- 建在主库，会通过复制同步到从库，从库上也能用它备份
CREATE USER IF NOT EXISTS 'backup'@'localhost' IDENTIFIED BY 'ChangeMe-Backup-123';
GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, EVENT, RELOAD, REPLICATION CLIENT, PROCESS ON *.* TO 'backup'@'localhost';

SELECT user, host, plugin FROM mysql.user WHERE user IN ('mall', 'repl', 'backup');
