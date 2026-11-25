// mall-api 是课程贯穿全部实验的示例商城后端。
//
// 设计目标：足够简单，方便学员读懂；同时具备生产服务该有的东西
// （健康检查、就绪检查、指标、结构化日志、优雅退出），方便做部署、监控、日志、故障演练实验。
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// version 在构建时通过 -ldflags "-X main.version=v1.0.0" 注入，也可以用 MALL_VERSION 覆盖。
var version = "dev"

func main() {
	cfg := loadConfig()
	logger := newLogger(cfg.LogLevel)
	slog.SetDefault(logger)

	store, err := newSQLStore(cfg.DBDSN)
	if err != nil {
		logger.Error("init database failed", "err", err)
		os.Exit(1)
	}
	defer store.Close()

	var cache Cache = noopCache{}
	if cfg.RedisAddr != "" {
		cache = newRedisCache(cfg.RedisAddr, cfg.RedisPassword)
	}

	app := &App{
		cfg:     cfg,
		store:   store,
		cache:   cache,
		metrics: newMetrics(),
		log:     logger,
	}

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           app.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		logger.Info("mall-api starting", "listen", cfg.Listen, "version", cfg.Version, "debug", cfg.Debug, "redis", cfg.RedisAddr != "")
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("http server failed", "err", err)
			os.Exit(1)
		}
	}()

	// 收到 SIGTERM（systemctl stop、K8s 删除 Pod）时优雅退出：不再接新请求，处理完已有请求。
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	sig := <-stop
	logger.Info("shutting down", "signal", sig.String(), "grace", cfg.ShutdownGrace.String())

	ctx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		logger.Error("graceful shutdown failed", "err", err)
	}
	logger.Info("bye")
}

func newLogger(level string) *slog.Logger {
	var lv slog.Level
	if err := lv.UnmarshalText([]byte(level)); err != nil {
		lv = slog.LevelInfo
	}
	// JSON 日志输出到标准输出：systemd 交给 journald，容器里交给容器运行时，方便日志实验采集。
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lv})
	return slog.New(h).With("service", "mall-api")
}
