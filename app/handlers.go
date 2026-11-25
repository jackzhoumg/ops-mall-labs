package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const productsCacheKey = "mall:products"

type App struct {
	cfg     Config
	store   Store
	cache   Cache
	metrics *Metrics
	log     *slog.Logger

	leakMu sync.Mutex
	leak   [][]byte // /api/debug/leak 故意持有的内存
}

func (a *App) routes() http.Handler {
	a.metrics.buildInfo.WithLabelValues(a.cfg.Version).Set(1)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", a.handleHealthz)
	mux.HandleFunc("GET /readyz", a.handleReadyz)
	mux.HandleFunc("GET /api/version", a.handleVersion)
	mux.HandleFunc("GET /api/products", a.handleListProducts)
	mux.HandleFunc("GET /api/products/{id}", a.handleGetProduct)
	mux.HandleFunc("POST /api/orders", a.handleCreateOrder)
	mux.HandleFunc("GET /api/orders/{id}", a.handleGetOrder)
	mux.Handle("GET /metrics", promhttp.HandlerFor(a.metrics.registry, promhttp.HandlerOpts{}))

	if a.cfg.Debug {
		mux.HandleFunc("GET /api/debug/slow", a.handleDebugSlow)
		mux.HandleFunc("GET /api/debug/error", a.handleDebugError)
		mux.HandleFunc("GET /api/debug/cpu", a.handleDebugCPU)
		mux.HandleFunc("GET /api/debug/leak", a.handleDebugLeak)
	}
	return a.middleware(mux)
}

// statusRecorder 记录响应状态码，给访问日志和指标用。
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func (a *App) middleware(next *http.ServeMux) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		reqID := r.Header.Get("X-Request-ID")
		if reqID == "" {
			reqID = newRequestID()
		}
		w.Header().Set("X-Request-ID", reqID)
		w.Header().Set("X-Mall-Version", a.cfg.Version)

		a.metrics.httpInflight.Inc()
		defer a.metrics.httpInflight.Dec()

		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)

		// 用路由模板（如 /api/products/{id}）做指标标签，避免 id 把标签数量撑爆。
		route := r.Pattern
		if route == "" {
			route = "unmatched"
		}
		dur := time.Since(start)
		a.metrics.httpRequests.WithLabelValues(r.Method, route, strconv.Itoa(rec.status)).Inc()
		a.metrics.httpDuration.WithLabelValues(r.Method, route).Observe(dur.Seconds())

		if r.URL.Path == "/healthz" || r.URL.Path == "/readyz" || r.URL.Path == "/metrics" {
			return // 探针和抓取请求太频繁，不写访问日志
		}
		level := slog.LevelInfo
		if rec.status >= 500 {
			level = slog.LevelError
		} else if rec.status >= 400 {
			level = slog.LevelWarn
		}
		a.log.Log(r.Context(), level, "access",
			"request_id", reqID,
			"method", r.Method,
			"path", r.URL.Path,
			"route", route,
			"status", rec.status,
			"duration_ms", float64(dur.Microseconds())/1000,
			"remote_addr", clientIP(r),
			"user_agent", r.UserAgent(),
		)
	})
}

func clientIP(r *http.Request) string {
	// 经过 Nginx 或 Ingress 时，真实客户端 IP 在 X-Real-IP / X-Forwarded-For 里。
	if ip := r.Header.Get("X-Real-IP"); ip != "" {
		return ip
	}
	if ip := r.Header.Get("X-Forwarded-For"); ip != "" {
		return ip
	}
	return r.RemoteAddr
}

func newRequestID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func pathID(r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	return id, err == nil && id > 0
}

// /healthz：进程活着就返回 200，不检查依赖。用作 K8s livenessProbe。
func (a *App) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// /readyz：数据库（以及启用时的 Redis）都能连上才返回 200。用作 readinessProbe 和负载均衡健康检查。
func (a *App) handleReadyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	checks := map[string]string{}
	ok := true
	if err := a.store.Ping(ctx); err != nil {
		checks["mysql"] = err.Error()
		ok = false
	} else {
		checks["mysql"] = "ok"
	}
	if a.cache.Enabled() {
		if err := a.cache.Ping(ctx); err != nil {
			checks["redis"] = err.Error()
			ok = false
		} else {
			checks["redis"] = "ok"
		}
	}
	status := http.StatusOK
	if !ok {
		status = http.StatusServiceUnavailable
	}
	writeJSON(w, status, map[string]any{"ready": ok, "checks": checks})
}

// /api/version：返回版本和主机名，负载均衡、灰度发布实验里用来确认请求落到了哪个实例。
func (a *App) handleVersion(w http.ResponseWriter, _ *http.Request) {
	host, _ := os.Hostname()
	writeJSON(w, http.StatusOK, map[string]string{"version": a.cfg.Version, "hostname": host})
}

func (a *App) handleListProducts(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	var products []Product
	if hit, err := a.cache.Get(ctx, productsCacheKey, &products); err != nil {
		a.log.Warn("cache get failed, fallback to db", "err", err)
	} else if hit {
		a.metrics.cacheHits.Inc()
		w.Header().Set("X-Cache", "HIT")
		writeJSON(w, http.StatusOK, products)
		return
	}
	if a.cache.Enabled() {
		a.metrics.cacheMisses.Inc()
		w.Header().Set("X-Cache", "MISS")
	}

	products, err := a.store.ListProducts(ctx)
	if err != nil {
		a.log.Error("list products failed", "err", err)
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}
	if products == nil {
		products = []Product{}
	}
	if err := a.cache.Set(ctx, productsCacheKey, products, a.cfg.CacheTTL); err != nil {
		a.log.Warn("cache set failed", "err", err)
	}
	writeJSON(w, http.StatusOK, products)
}

func (a *App) handleGetProduct(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}
	p, err := a.store.GetProduct(r.Context(), id)
	if errors.Is(err, ErrNotFound) {
		writeError(w, http.StatusNotFound, "product not found")
		return
	}
	if err != nil {
		a.log.Error("get product failed", "err", err, "id", id)
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}
	writeJSON(w, http.StatusOK, p)
}

type createOrderRequest struct {
	ProductID int64 `json:"product_id"`
	Quantity  int64 `json:"quantity"`
}

func (a *App) handleCreateOrder(w http.ResponseWriter, r *http.Request) {
	var req createOrderRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid json body")
		return
	}
	if req.ProductID <= 0 || req.Quantity <= 0 || req.Quantity > 100 {
		writeError(w, http.StatusBadRequest, "product_id must be > 0 and quantity must be 1-100")
		return
	}
	o, err := a.store.CreateOrder(r.Context(), req.ProductID, req.Quantity)
	switch {
	case errors.Is(err, ErrNotFound):
		writeError(w, http.StatusNotFound, "product not found")
		return
	case errors.Is(err, ErrInsufficientStock):
		writeError(w, http.StatusConflict, "insufficient stock")
		return
	case err != nil:
		a.log.Error("create order failed", "err", err)
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}
	a.metrics.ordersTotal.Inc()
	// 库存变了，删除商品列表缓存。
	if err := a.cache.Del(r.Context(), productsCacheKey); err != nil {
		a.log.Warn("cache del failed", "err", err)
	}
	a.log.Info("order created", "order_id", o.ID, "product_id", o.ProductID, "quantity", o.Quantity, "amount_cents", o.AmountCents)
	writeJSON(w, http.StatusCreated, o)
}

func (a *App) handleGetOrder(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid id")
		return
	}
	o, err := a.store.GetOrder(r.Context(), id)
	if errors.Is(err, ErrNotFound) {
		writeError(w, http.StatusNotFound, "order not found")
		return
	}
	if err != nil {
		a.log.Error("get order failed", "err", err, "id", id)
		writeError(w, http.StatusInternalServerError, "database error")
		return
	}
	writeJSON(w, http.StatusOK, o)
}

// ---- 故障演练接口，仅 MALL_DEBUG=true 时注册 ----

func queryInt(r *http.Request, key string, def, max int) int {
	v, err := strconv.Atoi(r.URL.Query().Get(key))
	if err != nil || v <= 0 {
		return def
	}
	if v > max {
		return max
	}
	return v
}

// /api/debug/slow?ms=2000：模拟慢接口。
func (a *App) handleDebugSlow(w http.ResponseWriter, r *http.Request) {
	ms := queryInt(r, "ms", 2000, 60000)
	select {
	case <-time.After(time.Duration(ms) * time.Millisecond):
		writeJSON(w, http.StatusOK, map[string]int{"slept_ms": ms})
	case <-r.Context().Done():
	}
}

// /api/debug/error：返回 500。
func (a *App) handleDebugError(w http.ResponseWriter, _ *http.Request) {
	a.log.Error("debug error triggered")
	writeError(w, http.StatusInternalServerError, "debug error")
}

// /api/debug/cpu?seconds=10：占满所有 CPU 核一段时间。
func (a *App) handleDebugCPU(w http.ResponseWriter, r *http.Request) {
	secs := queryInt(r, "seconds", 10, 300)
	deadline := time.Now().Add(time.Duration(secs) * time.Second)
	n := runtime.NumCPU()
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			x := 0
			for time.Now().Before(deadline) {
				x++
			}
			_ = x
		}()
	}
	wg.Wait()
	writeJSON(w, http.StatusOK, map[string]int{"burned_seconds": secs, "cores": n})
}

// /api/debug/leak?mb=50：每调用一次多占用 mb 兆内存且不释放，模拟内存泄漏。
func (a *App) handleDebugLeak(w http.ResponseWriter, r *http.Request) {
	mb := queryInt(r, "mb", 50, 1024)
	buf := make([]byte, mb<<20)
	for i := range buf {
		buf[i] = byte(i)
	}
	a.leakMu.Lock()
	a.leak = append(a.leak, buf)
	total := 0
	for _, b := range a.leak {
		total += len(b) >> 20
	}
	a.leakMu.Unlock()
	writeJSON(w, http.StatusOK, map[string]int{"added_mb": mb, "total_mb": total})
}
