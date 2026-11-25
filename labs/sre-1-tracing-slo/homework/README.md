# 课后作业：mall-api 接入 OpenTelemetry SDK

课上我们只在网关拿到了入口链路：Jaeger 里每个请求只有一个 Envoy 的 span，能看出“慢在网关后面”，看不出慢在哪条 SQL。
这个作业给 mall-api 打一个补丁，让链路延伸到应用内部和 MySQL / Redis。

**不要直接改仓库里的 `app/`**，在自己的分支或副本里打补丁。

## 文件

| 文件 | 用途 |
|---|---|
| `mall-api-otel.patch` | 对 `app/` 的补丁（git 格式），新增 `app/tracing.go`，改 `main.go` `handlers.go` `store.go` `go.mod` `go.sum` |
| `deployment-otel-env.yaml` | 新镜像上线时给 Deployment 加的 OTel 环境变量 |
| `grafana-datasource-jaeger.yaml` | 给 Grafana 加 Jaeger 数据源，配合 Loki 的 derived field 从日志跳到链路 |

## 补丁做了什么

| 改动 | 作用 |
|---|---|
| `setupTracing()`（tracing.go） | 设置了 `OTEL_EXPORTER_OTLP_ENDPOINT` 才启用，用 OTLP gRPC 把 span 发给 Collector；没设置时行为和原来完全一样 |
| W3C `traceparent` 传播器 | 接上网关 Envoy 传进来的 trace 上下文，网关 span 和应用 span 在同一条链路里 |
| `otelhttp.NewHandler`（main.go） | 每个请求一个服务端 span，跳过 `/healthz` `/readyz` `/metrics` |
| 中间件里 `span.SetName(route)` | span 名用路由模板（`GET /api/products/{id}`），和指标的 `route` 标签一致 |
| span 属性 `mall.request_id` | 链路里能看到请求 ID |
| 响应头 `X-Trace-ID` | 用户报障时把这个值贴过来，直接在 Jaeger 里打开 |
| `traceHandler`（tracing.go） | 带 context 的日志自动加 `trace_id` `span_id` 字段 |
| `otelsql.Open`（store.go） | 每条 SQL 一个子 span |
| `redisotel.InstrumentTracing`（store.go） | 每个 Redis 命令一个子 span |

写作时依赖版本（`go get ...@latest` 解析出来的，以实际为准）：
`go.opentelemetry.io/otel` v1.47.0、`otelhttp` v0.72.0、`github.com/XSAM/otelsql` v0.44.0、`redisotel/v9` v9.23.0。

## 步骤

### 1. 打补丁、编译、跑测试（开发机或 lab-dev）

```bash
git clone <你的 ops-mall-labs 仓库> mall-otel && cd mall-otel
git checkout -b feature/otel
git apply --check labs/sre-1-tracing-slo/homework/mall-api-otel.patch   # 先检查能不能干净地打上
git apply labs/sre-1-tracing-slo/homework/mall-api-otel.patch
cd app
go env -w GOPROXY=https://goproxy.cn,direct
go build ./... && go test ./...
```

预期：`ok  github.com/jackzhoumg/ops-mall-labs/app`。

### 2. 本地验证 trace_id 和日志关联（不需要 Collector）

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4317 OTEL_EXPORTER_OTLP_INSECURE=true \
MALL_LISTEN=127.0.0.1:18080 go run . &
curl -s -D - -o /dev/null \
  -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
  -H 'X-Request-ID: req-abc123' http://127.0.0.1:18080/api/version
```

预期响应头里有 `X-Trace-Id: 4bf92f3577b34da6a3ce929d0e0e4736`（沿用了传入的 trace ID），访问日志里同时有 `"request_id":"req-abc123"` 和 `"trace_id":"4bf92f3577b34da6a3ce929d0e0e4736"`。
没有 Collector 时 SDK 会在后台报发送失败，不影响请求。

### 3. 构建镜像、上线（lab-dev → k8s-master）

```bash
# lab-dev，仓库根目录
docker build -f labs/lab04-docker/Dockerfile.api -t harbor.lab.local/mall/mall-api:v1.1.0-otel .
docker push harbor.lab.local/mall/mall-api:v1.1.0-otel

# k8s-master
kubectl -n mall patch deployment mall-api --type strategic --patch-file homework/deployment-otel-env.yaml
kubectl -n mall set image deployment/mall-api mall-api=harbor.lab.local/mall/mall-api:v1.1.0-otel
kubectl -n mall rollout status deployment/mall-api
```

如果走 Lab 08 的 GitOps，改 Helm values 里的镜像 tag 和 env，提交到 Git，让 ArgoCD 去同步，不要手工 patch（手工改会被 ArgoCD 改回去）。

### 4. 验收

- Jaeger 里搜 `mall-api` 服务，一条 `GET /api/products` 链路有三层：Envoy span → `GET /api/products` → SQL 查询 span 或 Redis `get` span
- 下单链路里能看到开事务、`SELECT ... FOR UPDATE`、`UPDATE`、`INSERT`、提交各自的耗时（span 名以 otelsql 实际输出为准，形如 `sql.conn.query`，SQL 语句在 span 属性里）
- Grafana Explore 选 `Loki-mall` 数据源，用 `{namespace="mall", app="mall-api"} | json | trace_id="<从 Jaeger 复制的 trace ID>"` 能搜到这个请求的访问日志

## trace_id 和 request_id 怎么关联

| 场景 | 用什么关联 |
|---|---|
| 只有网关链路（课上做的） | Envoy 给每个请求生成 `x-request-id` 并转给 mall-api；Envoy span 上有 `request_id` 标签，mall-api 访问日志有 `request_id` 字段。拿日志里的 request_id 到 Jaeger 按标签 `request_id=<值>` 搜 |
| 接了 SDK（本作业） | 日志直接带 `trace_id`。`kubectl apply -f homework/grafana-datasource-jaeger.yaml` 加 Jaeger 数据源，再按该文件注释给 Lab 10 的 `Loki-mall` 数据源追加一个 derived field（正则 `"trace_id":"(\w+)"`，链接到 Jaeger），日志里就会出现一个按钮直接跳到链路 |
| 用户报障 | 让用户（或前端错误上报）带上响应头里的 `X-Request-ID` / `X-Trace-ID` |

两个 ID 各有用处：request_id 是业务层的，任何组件（Nginx、网关、应用）都能透传，不依赖追踪系统；trace_id 是追踪系统的，能把一个请求经过的所有服务串起来。生产上两个都留。

## 进阶思考

1. 100% 采样太贵。在 Collector 里加 `tail_sampling` 处理器，只保留“出错的”和“超过 500ms 的”链路，再随机留 5% 正常链路。
2. 补丁里只把访问日志和下单日志改成了 `InfoContext`/`ErrorContext`。把其他日志也改掉，所有日志都会带上 trace_id。
3. 用 Collector 的 `spanmetrics` connector 从链路生成 RED 指标，对比和 mall-api 自己暴露的指标有什么差别。
