package main

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
)

// Metrics 是监控实验（Lab 09）和 SLO 实验（SRE-1）用到的业务与 HTTP 指标。
type Metrics struct {
	registry     *prometheus.Registry
	httpRequests *prometheus.CounterVec
	httpDuration *prometheus.HistogramVec
	httpInflight prometheus.Gauge
	ordersTotal  prometheus.Counter
	cacheHits    prometheus.Counter
	cacheMisses  prometheus.Counter
	buildInfo    *prometheus.GaugeVec
}

func newMetrics() *Metrics {
	reg := prometheus.NewRegistry()
	m := &Metrics{
		registry: reg,
		httpRequests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "mall_http_requests_total",
			Help: "HTTP 请求总数，按方法、路由、状态码区分",
		}, []string{"method", "route", "status"}),
		httpDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "mall_http_request_duration_seconds",
			Help:    "HTTP 请求耗时",
			Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
		}, []string{"method", "route"}),
		httpInflight: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "mall_http_inflight_requests",
			Help: "正在处理的请求数",
		}),
		ordersTotal: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "mall_orders_created_total",
			Help: "成功创建的订单数",
		}),
		cacheHits: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "mall_cache_hits_total",
			Help: "商品列表缓存命中次数",
		}),
		cacheMisses: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "mall_cache_misses_total",
			Help: "商品列表缓存未命中次数",
		}),
		buildInfo: prometheus.NewGaugeVec(prometheus.GaugeOpts{
			Name: "mall_build_info",
			Help: "构建信息，值恒为 1",
		}, []string{"version"}),
	}
	reg.MustRegister(
		m.httpRequests, m.httpDuration, m.httpInflight,
		m.ordersTotal, m.cacheHits, m.cacheMisses, m.buildInfo,
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)
	return m
}
