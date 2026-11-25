// mall-api 混合场景压测脚本（k6）。
// 写作时版本：k6 v2.4.0，文档 https://grafana.com/docs/k6/latest/ ，以官方最新文档为准。
//
// 两个场景按到达速率（每秒请求数）加压，而不是按虚拟用户数：
//   browse：看商品列表（2/3）和商品详情（1/3），占总流量 90%
//   order ：下单，占总流量 10%
//
// 用法（集群外的压测机，比如学员电脑）：
//   k6 run -e PROFILE=smoke k6/mall-load.js                      # 冒烟：确认脚本和环境没问题
//   k6 run -e PROFILE=step  -e PEAK_RPS=300 k6/mall-load.js      # 阶梯加压到 300 RPS，找单实例/当前副本的容量
//   k6 run -e PROFILE=stress -e PEAK_RPS=300 k6/mall-load.js     # 压到 2 倍峰值，找拐点，错误率过高自动停止
//   k6 run -e PROFILE=soak  -e PEAK_RPS=300 k6/mall-load.js      # 60% 峰值跑 30 分钟，看内存泄漏、连接泄漏
//
// 环境变量：
//   BASE_URL   默认 http://mall.lab.local
//   PROFILE    smoke / step / stress / soak，默认 smoke
//   PEAK_RPS   目标峰值总 RPS，默认 200
//   INSECURE   自签证书时设成 true
//   RUN_ID     本次压测编号，写进 User-Agent，方便在日志里筛选，默认用启动时间
//   HOT_PRODUCT 设成商品 ID（如 5）时，所有订单都抢这一个商品，模拟秒杀的热点行锁
import http from 'k6/http';
import { check } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL || 'http://mall.lab.local';
const PROFILE = __ENV.PROFILE || 'smoke';
const PEAK_RPS = Number(__ENV.PEAK_RPS || 200);
const RUN_ID = __ENV.RUN_ID || new Date().toISOString().replace(/[-:]/g, '').slice(0, 15);
const HOT_PRODUCT = Number(__ENV.HOT_PRODUCT || 0);

const BROWSE_SHARE = 0.9;
const ORDER_SHARE = 0.1;

// 流量标记：所有压测请求都带上，日志、网关、下游都能据此识别和过滤压测流量
const HEADERS = {
  'User-Agent': `k6-loadtest/sre-2 run=${RUN_ID}`,
  'X-Load-Test': 'true',
};

// 自定义指标：下单因库存不足被拒（409）的次数。409 是正常业务结果，不算失败，但要盯着
const outOfStock = new Counter('mall_order_out_of_stock');
const orderLatency = new Trend('mall_order_duration', true);

// 把“目标总 RPS 的百分比”换成某个场景的 RPS，至少 1
function rate(share, pct) {
  return Math.max(1, Math.round(PEAK_RPS * share * pct));
}

// 阶梯：每级 1 分钟爬坡 + 3 分钟稳定，稳定段的数据才用来算容量
function steps(share, levels) {
  const out = [];
  for (const pct of levels) {
    out.push({ target: rate(share, pct), duration: '1m' });
    out.push({ target: rate(share, pct), duration: '3m' });
  }
  out.push({ target: 0, duration: '1m' });
  return out;
}

function arrivalScenario(exec, share, stages) {
  return {
    executor: 'ramping-arrival-rate',
    exec,
    startRate: rate(share, 0.1),
    timeUnit: '1s',
    // 预先分配的 VU 数要够：每个 VU 同一时间只能发一个请求，接口变慢时需要的 VU 会变多。
    // VU 不够时 k6 会丢弃迭代（dropped_iterations），实际压力达不到目标。
    // 需要的 VU 约等于 RPS × 平均响应时间（秒），50ms 的接口 300 RPS 只要 15 个 VU
    preAllocatedVUs: Math.max(10, Math.ceil(rate(share, 1) * 0.3)),
    maxVUs: Math.max(50, rate(share, 2)),
    stages,
  };
}

const PROFILES = {
  smoke: {
    browse: { executor: 'constant-arrival-rate', exec: 'browse', rate: 5, timeUnit: '1s', duration: '1m', preAllocatedVUs: 5, maxVUs: 20 },
    order: { executor: 'constant-arrival-rate', exec: 'order', rate: 1, timeUnit: '1s', duration: '1m', preAllocatedVUs: 2, maxVUs: 10 },
  },
  step: {
    browse: arrivalScenario('browse', BROWSE_SHARE, steps(BROWSE_SHARE, [0.2, 0.4, 0.6, 0.8, 1.0])),
    order: arrivalScenario('order', ORDER_SHARE, steps(ORDER_SHARE, [0.2, 0.4, 0.6, 0.8, 1.0])),
  },
  stress: {
    browse: arrivalScenario('browse', BROWSE_SHARE, steps(BROWSE_SHARE, [0.5, 1.0, 1.5, 2.0])),
    order: arrivalScenario('order', ORDER_SHARE, steps(ORDER_SHARE, [0.5, 1.0, 1.5, 2.0])),
  },
  soak: {
    browse: arrivalScenario('browse', BROWSE_SHARE, [
      { target: rate(BROWSE_SHARE, 0.6), duration: '2m' },
      { target: rate(BROWSE_SHARE, 0.6), duration: '30m' },
      { target: 0, duration: '1m' },
    ]),
    order: arrivalScenario('order', ORDER_SHARE, [
      { target: rate(ORDER_SHARE, 0.6), duration: '2m' },
      { target: rate(ORDER_SHARE, 0.6), duration: '30m' },
      { target: 0, duration: '1m' },
    ]),
  },
};

if (!PROFILES[PROFILE]) {
  throw new Error(`未知的 PROFILE=${PROFILE}，可选：${Object.keys(PROFILES).join(' / ')}`);
}

// 阈值和 SRE-1 的 SLO 对齐：压测通过 = 这个压力下 SLO 还守得住
const thresholds = {
  'http_req_failed{scenario:browse}': ['rate<0.001'], // 可用性 99.9%
  'http_req_failed{scenario:order}': ['rate<0.001'],
  'http_req_duration{scenario:browse}': ['p(99)<500'], // 延迟：99% 请求 500ms 内
  'http_req_duration{scenario:order}': ['p(99)<800'],
  checks: ['rate>0.99'],
  // 压测机自己扛不住（VU 不够）时会丢迭代，丢多了说明结果不可信
  dropped_iterations: ['count<100'],
};

if (PROFILE === 'stress') {
  // 摸拐点时，错误率超过 5% 就自动停，别把环境打垮
  thresholds['http_req_failed'] = [{ threshold: 'rate<0.05', abortOnFail: true, delayAbortEval: '30s' }];
}

export const options = {
  scenarios: PROFILES[PROFILE],
  thresholds,
  insecureSkipTLSVerify: __ENV.INSECURE === 'true',
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  // 每个请求按路由模板打标签，避免带 id 的 URL 让指标数量爆炸
  tags: { profile: PROFILE, run_id: RUN_ID },
};

export function setup() {
  const res = http.get(`${BASE_URL}/api/products`, { headers: HEADERS, tags: { name: 'GET /api/products' } });
  if (res.status !== 200) {
    throw new Error(`预检失败：GET ${BASE_URL}/api/products 返回 ${res.status}，先确认服务和 hosts`);
  }
  const products = res.json();
  return { productIds: products.map((p) => p.id) };
}

export function browse(data) {
  if (Math.random() < 2 / 3) {
    const res = http.get(`${BASE_URL}/api/products`, { headers: HEADERS, tags: { name: 'GET /api/products' } });
    check(res, {
      'list 200': (r) => r.status === 200,
      'list not empty': (r) => r.status === 200 && r.json().length > 0,
    });
  } else {
    const id = data.productIds[Math.floor(Math.random() * data.productIds.length)];
    const res = http.get(`${BASE_URL}/api/products/${id}`, { headers: HEADERS, tags: { name: 'GET /api/products/{id}' } });
    check(res, { 'detail 200': (r) => r.status === 200 });
  }
}

export function order(data) {
  // 默认随机选商品；所有订单都抢同一个商品是“热点行锁”测试（秒杀场景），用 HOT_PRODUCT 单独压
  const id = HOT_PRODUCT > 0 ? HOT_PRODUCT : data.productIds[Math.floor(Math.random() * data.productIds.length)];
  const res = http.post(
    `${BASE_URL}/api/orders`,
    JSON.stringify({ product_id: id, quantity: 1 }),
    {
      headers: Object.assign({ 'Content-Type': 'application/json' }, HEADERS),
      tags: { name: 'POST /api/orders' },
      // 201 成功、409 库存不足都是预期内的业务结果，不计入 http_req_failed
      responseCallback: http.expectedStatuses(201, 409),
    },
  );
  if (res.status === 409) {
    outOfStock.add(1);
  }
  orderLatency.add(res.timings.duration);
  check(res, { 'order 201/409': (r) => r.status === 201 || r.status === 409 });
}

// 压测结束后另存一份 JSON 结果，写进容量评估报告
export function handleSummary(data) {
  const m = data.metrics;
  const v = (name, stat) => (m[name] && m[name].values[stat] !== undefined ? m[name].values[stat] : NaN);
  const lines = [
    '',
    `===== mall-api 压测结果  profile=${PROFILE}  peak=${PEAK_RPS} RPS  run=${RUN_ID} =====`,
    `总请求数        ${v('http_reqs', 'count')}`,
    `平均 RPS        ${v('http_reqs', 'rate').toFixed(1)}`,
    `失败率          ${(v('http_req_failed', 'rate') * 100).toFixed(3)}%`,
    `延迟 p95 / p99  ${v('http_req_duration', 'p(95)').toFixed(1)} ms / ${v('http_req_duration', 'p(99)').toFixed(1)} ms`,
    `下单 p99        ${v('mall_order_duration', 'p(99)').toFixed(1)} ms`,
    `库存不足(409)   ${v('mall_order_out_of_stock', 'count') || 0}`,
    `丢弃的迭代      ${v('dropped_iterations', 'count') || 0}`,
    '阈值：',
  ];
  for (const [name, metric] of Object.entries(m)) {
    if (metric.thresholds) {
      for (const [expr, res] of Object.entries(metric.thresholds)) {
        lines.push(`  ${res.ok ? '通过' : '失败'}  ${name}  ${expr}`);
      }
    }
  }
  lines.push('');
  return {
    stdout: lines.join('\n'),
    [`summary-${PROFILE}-${RUN_ID}.json`]: JSON.stringify(data, null, 2),
  };
}
