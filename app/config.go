package main

import (
	"os"
	"strconv"
	"time"
)

// Config 全部来自环境变量，符合十二要素应用的做法：同一个二进制 / 镜像，换环境只改变量。
type Config struct {
	Listen        string        // MALL_LISTEN，默认 :8080
	DBDSN         string        // MALL_DB_DSN，MySQL 连接串
	RedisAddr     string        // MALL_REDIS_ADDR，留空表示不用缓存
	RedisPassword string        // MALL_REDIS_PASSWORD
	CacheTTL      time.Duration // MALL_CACHE_TTL，商品列表缓存时间，默认 30s
	Version       string        // MALL_VERSION，默认取构建时注入的版本号
	Debug         bool          // MALL_DEBUG=true 时开启故障演练接口 /api/debug/*
	LogLevel      string        // MALL_LOG_LEVEL：debug / info / warn / error
	ShutdownGrace time.Duration // MALL_SHUTDOWN_GRACE，优雅退出等待时间，默认 10s
}

func loadConfig() Config {
	return Config{
		Listen:        env("MALL_LISTEN", ":8080"),
		DBDSN:         env("MALL_DB_DSN", "mall:MallPass123@tcp(127.0.0.1:3306)/mall?parseTime=true&timeout=3s"),
		RedisAddr:     env("MALL_REDIS_ADDR", ""),
		RedisPassword: env("MALL_REDIS_PASSWORD", ""),
		CacheTTL:      envDuration("MALL_CACHE_TTL", 30*time.Second),
		Version:       env("MALL_VERSION", version),
		Debug:         envBool("MALL_DEBUG", false),
		LogLevel:      env("MALL_LOG_LEVEL", "info"),
		ShutdownGrace: envDuration("MALL_SHUTDOWN_GRACE", 10*time.Second),
	}
}

func env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func envBool(key string, def bool) bool {
	if v, err := strconv.ParseBool(os.Getenv(key)); err == nil {
		return v
	}
	return def
}

func envDuration(key string, def time.Duration) time.Duration {
	if v, err := time.ParseDuration(os.Getenv(key)); err == nil && v > 0 {
		return v
	}
	return def
}
