package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

type memStore struct {
	mu       sync.Mutex
	products map[int64]Product
	orders   []Order
	pingErr  error
}

func newMemStore() *memStore {
	return &memStore{products: map[int64]Product{
		1: {ID: 1, Name: "机械键盘", PriceCents: 29900, Stock: 10},
		2: {ID: 2, Name: "降噪耳机", PriceCents: 59900, Stock: 1},
	}}
}

func (m *memStore) Ping(context.Context) error { return m.pingErr }
func (m *memStore) Close() error               { return nil }

func (m *memStore) ListProducts(context.Context) ([]Product, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []Product{m.products[1], m.products[2]}
	return out, nil
}

func (m *memStore) GetProduct(_ context.Context, id int64) (Product, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	p, ok := m.products[id]
	if !ok {
		return p, ErrNotFound
	}
	return p, nil
}

func (m *memStore) CreateOrder(_ context.Context, pid, qty int64) (Order, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	p, ok := m.products[pid]
	if !ok {
		return Order{}, ErrNotFound
	}
	if p.Stock < qty {
		return Order{}, ErrInsufficientStock
	}
	p.Stock -= qty
	m.products[pid] = p
	o := Order{ID: int64(len(m.orders) + 1), ProductID: pid, Quantity: qty, AmountCents: p.PriceCents * qty, CreatedAt: time.Now()}
	m.orders = append(m.orders, o)
	return o, nil
}

func (m *memStore) GetOrder(_ context.Context, id int64) (Order, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if id < 1 || int(id) > len(m.orders) {
		return Order{}, ErrNotFound
	}
	return m.orders[id-1], nil
}

func newTestApp(store Store, debug bool) http.Handler {
	app := &App{
		cfg:     Config{Version: "test", Debug: debug, CacheTTL: time.Second},
		store:   store,
		cache:   noopCache{},
		metrics: newMetrics(),
		log:     slog.New(slog.NewJSONHandler(io.Discard, nil)),
	}
	return app.routes()
}

func do(t *testing.T, h http.Handler, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	var r io.Reader
	if body != "" {
		r = strings.NewReader(body)
	}
	req := httptest.NewRequest(method, path, r)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestHealthAndReady(t *testing.T) {
	s := newMemStore()
	h := newTestApp(s, false)

	if rec := do(t, h, "GET", "/healthz", ""); rec.Code != 200 {
		t.Fatalf("healthz = %d", rec.Code)
	}
	if rec := do(t, h, "GET", "/readyz", ""); rec.Code != 200 {
		t.Fatalf("readyz = %d", rec.Code)
	}
	s.pingErr = errors.New("connection refused")
	if rec := do(t, h, "GET", "/readyz", ""); rec.Code != 503 {
		t.Fatalf("readyz with db down = %d, want 503", rec.Code)
	}
}

func TestProducts(t *testing.T) {
	h := newTestApp(newMemStore(), false)

	rec := do(t, h, "GET", "/api/products", "")
	if rec.Code != 200 {
		t.Fatalf("list = %d", rec.Code)
	}
	var ps []Product
	if err := json.Unmarshal(rec.Body.Bytes(), &ps); err != nil || len(ps) != 2 {
		t.Fatalf("list body = %s", rec.Body.String())
	}
	if rec := do(t, h, "GET", "/api/products/1", ""); rec.Code != 200 {
		t.Fatalf("get = %d", rec.Code)
	}
	if rec := do(t, h, "GET", "/api/products/99", ""); rec.Code != 404 {
		t.Fatalf("get missing = %d", rec.Code)
	}
	if rec := do(t, h, "GET", "/api/products/abc", ""); rec.Code != 400 {
		t.Fatalf("get bad id = %d", rec.Code)
	}
	if rec.Header().Get("X-Request-ID") == "" {
		t.Fatal("missing X-Request-ID")
	}
}

func TestOrders(t *testing.T) {
	h := newTestApp(newMemStore(), false)

	rec := do(t, h, "POST", "/api/orders", `{"product_id":1,"quantity":2}`)
	if rec.Code != 201 {
		t.Fatalf("create = %d %s", rec.Code, rec.Body.String())
	}
	var o Order
	_ = json.Unmarshal(rec.Body.Bytes(), &o)
	if o.AmountCents != 59800 {
		t.Fatalf("amount = %d", o.AmountCents)
	}
	if rec := do(t, h, "GET", "/api/orders/1", ""); rec.Code != 200 {
		t.Fatalf("get order = %d", rec.Code)
	}
	if rec := do(t, h, "POST", "/api/orders", `{"product_id":2,"quantity":5}`); rec.Code != 409 {
		t.Fatalf("insufficient stock = %d", rec.Code)
	}
	if rec := do(t, h, "POST", "/api/orders", `{"product_id":0,"quantity":1}`); rec.Code != 400 {
		t.Fatalf("bad request = %d", rec.Code)
	}
	if rec := do(t, h, "POST", "/api/orders", `not json`); rec.Code != 400 {
		t.Fatalf("bad json = %d", rec.Code)
	}
}

func TestMetricsExposed(t *testing.T) {
	h := newTestApp(newMemStore(), false)
	do(t, h, "GET", "/api/products/1", "")
	rec := do(t, h, "GET", "/metrics", "")
	body := rec.Body.String()
	for _, want := range []string{
		`mall_http_requests_total{method="GET",route="GET /api/products/{id}",status="200"} 1`,
		`mall_build_info{version="test"} 1`,
		"mall_http_request_duration_seconds_bucket",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("metrics missing %q", want)
		}
	}
}

func TestDebugEndpointsOnlyWhenEnabled(t *testing.T) {
	off := newTestApp(newMemStore(), false)
	if rec := do(t, off, "GET", "/api/debug/error", ""); rec.Code != 404 {
		t.Fatalf("debug disabled = %d, want 404", rec.Code)
	}
	on := newTestApp(newMemStore(), true)
	if rec := do(t, on, "GET", "/api/debug/error", ""); rec.Code != 500 {
		t.Fatalf("debug error = %d, want 500", rec.Code)
	}
	if rec := do(t, on, "GET", "/api/debug/slow?ms=10", ""); rec.Code != 200 {
		t.Fatalf("debug slow = %d", rec.Code)
	}
	rec := do(t, on, "GET", "/api/debug/leak?mb=1", "")
	if !bytes.Contains(rec.Body.Bytes(), []byte(`"total_mb":1`)) {
		t.Fatalf("debug leak body = %s", rec.Body.String())
	}
}
