package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"github.com/redis/go-redis/v9"
)

type Product struct {
	ID         int64  `json:"id"`
	Name       string `json:"name"`
	PriceCents int64  `json:"price_cents"`
	Stock      int64  `json:"stock"`
}

type Order struct {
	ID          int64     `json:"id"`
	ProductID   int64     `json:"product_id"`
	Quantity    int64     `json:"quantity"`
	AmountCents int64     `json:"amount_cents"`
	CreatedAt   time.Time `json:"created_at"`
}

var (
	ErrNotFound          = errors.New("not found")
	ErrInsufficientStock = errors.New("insufficient stock")
)

// Store 抽象数据访问，单元测试里用内存实现替换。
type Store interface {
	Ping(ctx context.Context) error
	ListProducts(ctx context.Context) ([]Product, error)
	GetProduct(ctx context.Context, id int64) (Product, error)
	CreateOrder(ctx context.Context, productID, quantity int64) (Order, error)
	GetOrder(ctx context.Context, id int64) (Order, error)
	Close() error
}

type sqlStore struct{ db *sql.DB }

// newSQLStore 不会在启动时连接数据库（sql.Open 是惰性的），
// 数据库暂时不可用时服务照样能启动，由 /readyz 报告未就绪。
func newSQLStore(dsn string) (*sqlStore, error) {
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(20)
	db.SetMaxIdleConns(10)
	db.SetConnMaxLifetime(30 * time.Minute)
	return &sqlStore{db: db}, nil
}

func (s *sqlStore) Close() error { return s.db.Close() }

func (s *sqlStore) Ping(ctx context.Context) error { return s.db.PingContext(ctx) }

func (s *sqlStore) ListProducts(ctx context.Context) ([]Product, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, name, price_cents, stock FROM products ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Product
	for rows.Next() {
		var p Product
		if err := rows.Scan(&p.ID, &p.Name, &p.PriceCents, &p.Stock); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *sqlStore) GetProduct(ctx context.Context, id int64) (Product, error) {
	var p Product
	err := s.db.QueryRowContext(ctx, `SELECT id, name, price_cents, stock FROM products WHERE id = ?`, id).
		Scan(&p.ID, &p.Name, &p.PriceCents, &p.Stock)
	if errors.Is(err, sql.ErrNoRows) {
		return p, ErrNotFound
	}
	return p, err
}

// CreateOrder 在一个事务里扣库存并写订单，避免超卖。
func (s *sqlStore) CreateOrder(ctx context.Context, productID, quantity int64) (Order, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Order{}, err
	}
	defer tx.Rollback() //nolint:errcheck // 提交后再回滚是空操作

	var price int64
	err = tx.QueryRowContext(ctx, `SELECT price_cents FROM products WHERE id = ? FOR UPDATE`, productID).Scan(&price)
	if errors.Is(err, sql.ErrNoRows) {
		return Order{}, ErrNotFound
	}
	if err != nil {
		return Order{}, err
	}

	res, err := tx.ExecContext(ctx, `UPDATE products SET stock = stock - ? WHERE id = ? AND stock >= ?`, quantity, productID, quantity)
	if err != nil {
		return Order{}, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return Order{}, ErrInsufficientStock
	}

	amount := price * quantity
	res, err = tx.ExecContext(ctx, `INSERT INTO orders (product_id, quantity, amount_cents) VALUES (?, ?, ?)`, productID, quantity, amount)
	if err != nil {
		return Order{}, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return Order{}, err
	}
	if err := tx.Commit(); err != nil {
		return Order{}, err
	}
	return Order{ID: id, ProductID: productID, Quantity: quantity, AmountCents: amount, CreatedAt: time.Now().UTC()}, nil
}

func (s *sqlStore) GetOrder(ctx context.Context, id int64) (Order, error) {
	var o Order
	err := s.db.QueryRowContext(ctx, `SELECT id, product_id, quantity, amount_cents, created_at FROM orders WHERE id = ?`, id).
		Scan(&o.ID, &o.ProductID, &o.Quantity, &o.AmountCents, &o.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return o, ErrNotFound
	}
	return o, err
}

// Cache 是可选的商品列表缓存。
type Cache interface {
	Ping(ctx context.Context) error
	Get(ctx context.Context, key string, dst any) (bool, error)
	Set(ctx context.Context, key string, v any, ttl time.Duration) error
	Del(ctx context.Context, key string) error
	Enabled() bool
}

type noopCache struct{}

func (noopCache) Ping(context.Context) error                            { return nil }
func (noopCache) Get(context.Context, string, any) (bool, error)        { return false, nil }
func (noopCache) Set(context.Context, string, any, time.Duration) error { return nil }
func (noopCache) Del(context.Context, string) error                     { return nil }
func (noopCache) Enabled() bool                                         { return false }

type redisCache struct{ c *redis.Client }

func newRedisCache(addr, password string) *redisCache {
	return &redisCache{c: redis.NewClient(&redis.Options{
		Addr:     addr,
		Password: password,
		// 缓存只是加速手段：Redis 不可用时要快速失败、回退到数据库，不能拖慢接口
		DialTimeout:  500 * time.Millisecond,
		ReadTimeout:  300 * time.Millisecond,
		WriteTimeout: 300 * time.Millisecond,
		MaxRetries:   -1, // 命令失败不重试（go-redis 里 -1 表示关闭重试）
		// 建连失败也只试一次（默认会重试 5 次，Redis 挂掉时每个请求要多等 2-3 秒）
		DialerRetries: 1,
	})}
}

func (r *redisCache) Enabled() bool { return true }

func (r *redisCache) Ping(ctx context.Context) error { return r.c.Ping(ctx).Err() }

func (r *redisCache) Get(ctx context.Context, key string, dst any) (bool, error) {
	b, err := r.c.Get(ctx, key).Bytes()
	if errors.Is(err, redis.Nil) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, json.Unmarshal(b, dst)
}

func (r *redisCache) Set(ctx context.Context, key string, v any, ttl time.Duration) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return r.c.Set(ctx, key, b, ttl).Err()
}

func (r *redisCache) Del(ctx context.Context, key string) error { return r.c.Del(ctx, key).Err() }
