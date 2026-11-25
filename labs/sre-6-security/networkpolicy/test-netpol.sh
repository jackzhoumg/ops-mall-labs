#!/usr/bin/env bash
# test-netpol.sh：验证 mall 命名空间的 NetworkPolicy 是否“该通的通、该断的断”。
# 对应教程：SRE-6 集群安全加固 5.5 节
#
# 用法（在 k8s-master 上执行；本机要能解析 mall.lab.local）：
#   bash test-netpol.sh
#   CURL_IMAGE=harbor.lab.local/library/curl:8.23.0 bash test-netpol.sh
#
# 做法：在 mall 和 default 命名空间各起一个“陌生”测试 Pod（没有任何放行规则匹配它），
# 从它们去连 mall-api 和数据库，应该全部超时；再从网关入口访问商城，应该正常。
# 测试 Pod 满足 Pod Security restricted，所以 mall 命名空间 enforce=restricted 时也能创建。
set -uo pipefail

CURL_IMAGE="${CURL_IMAGE:-harbor.lab.local/library/curl:8.23.0}"
DB_IP="${DB_IP:-192.168.56.13}"
MALL_URL="${MALL_URL:-http://mall.lab.local/api/products}"
fail=0

start_tester() {
  local ns="$1"
  kubectl -n "$ns" delete pod netpol-tester --ignore-not-found --wait=true >/dev/null
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: netpol-tester
  namespace: $ns
  labels:
    app.kubernetes.io/name: netpol-tester
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: curl
      image: $CURL_IMAGE
      command: ["sleep", "600"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
EOF
  kubectl -n "$ns" wait --for=condition=Ready pod/netpol-tester --timeout=90s >/dev/null
}

# expect: ok = 应该连得上；blocked = 应该连不上
probe() {
  local expect="$1" ns="$2" desc="$3" url="$4"
  # 只看 TCP 有没有建立：time_connect 为 0 说明三次握手没完成（被策略丢弃）。
  # 这样 HTTP 和 MySQL / Redis 这种非 HTTP 端口（telnet://）能用同一种判断方法。
  local tconn result
  tconn="$(kubectl -n "$ns" exec netpol-tester -- \
    curl -s -o /dev/null --connect-timeout 3 -m 4 -w '%{time_connect}' "$url" </dev/null 2>/dev/null || true)"
  if [[ -n "$tconn" && "$tconn" != "0" && "$tconn" != "0.000000" ]]; then
    result="ok"
  else
    result="blocked"
  fi
  if [[ "$result" == "$expect" ]]; then
    printf '[PASS] %-8s %s\n' "$result" "$desc"
  else
    printf '[FAIL] 期望 %s 实际 %s：%s\n' "$expect" "$result" "$desc"
    fail=1
  fi
}

echo "== 准备测试 Pod（镜像 ${CURL_IMAGE}）"
start_tester mall
start_tester default

echo "== 应该被拦住的"
probe blocked mall "mall 里的陌生 Pod -> mall-api:8080" "http://mall-api.mall.svc:8080/healthz"
probe blocked mall "mall 里的陌生 Pod -> 数据库 ${DB_IP}:3306" "telnet://${DB_IP}:3306"
probe blocked default "default 命名空间 -> mall-api:8080" "http://mall-api.mall.svc:8080/healthz"
probe blocked default "default 命名空间 -> mall-web" "http://mall-web.mall.svc:80/"

echo "== 应该放行的"
code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$MALL_URL" || true)"
if [[ "$code" == "200" ]]; then
  echo "[PASS] ok       网关 -> mall-web / mall-api（$MALL_URL 返回 200）"
else
  echo "[FAIL] 网关访问 $MALL_URL 返回 ${code:-超时}"
  fail=1
fi
prom_pod="$(kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "$prom_pod" ]]; then
  if kubectl -n monitoring exec "$prom_pod" -c prometheus -- wget -q -T 3 -O /dev/null http://mall-api.mall.svc:8080/metrics 2>/dev/null; then
    echo "[PASS] ok       Prometheus -> mall-api /metrics"
  else
    echo "[FAIL] Prometheus 抓不到 mall-api /metrics"
    fail=1
  fi
else
  echo "[SKIP] 没找到 Prometheus Pod"
fi

echo "== 清理测试 Pod"
kubectl -n mall delete pod netpol-tester --wait=false >/dev/null
kubectl -n default delete pod netpol-tester --wait=false >/dev/null

exit "$fail"
