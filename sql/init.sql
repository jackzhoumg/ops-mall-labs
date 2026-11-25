-- ops-mall 数据库初始化脚本（MySQL 8.0 / 8.4）
-- 用法：mysql -uroot -p < sql/init.sql

CREATE DATABASE IF NOT EXISTS mall DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;

-- 应用账号：只授予 mall 库的增删改查权限（最小权限）。实验密码，生产环境请换成强密码。
CREATE USER IF NOT EXISTS 'mall'@'%' IDENTIFIED BY 'MallPass123';
GRANT SELECT, INSERT, UPDATE, DELETE ON mall.* TO 'mall'@'%';
FLUSH PRIVILEGES;

USE mall;

CREATE TABLE IF NOT EXISTS products (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  name        VARCHAR(100)    NOT NULL,
  price_cents BIGINT          NOT NULL COMMENT '价格，单位：分',
  stock       BIGINT          NOT NULL DEFAULT 0,
  created_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS orders (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  product_id   BIGINT UNSIGNED NOT NULL,
  quantity     BIGINT          NOT NULL,
  amount_cents BIGINT          NOT NULL,
  created_at   DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_product_id (product_id),
  KEY idx_created_at (created_at)
) ENGINE=InnoDB;

INSERT INTO products (id, name, price_cents, stock) VALUES
  (1, '机械键盘',       29900, 100),
  (2, '降噪耳机',       59900, 50),
  (3, '人体工学椅',    129900, 20),
  (4, '4K 显示器',     199900, 30),
  (5, '运维值班咖啡',    1500, 999),
  (6, 'Linux 入门手册',  4900, 200)
ON DUPLICATE KEY UPDATE name = VALUES(name);
