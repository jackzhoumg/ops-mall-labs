#!/usr/bin/env python3
"""区块高度对比：自建节点之间、自建节点和外部参考节点之间的高度差，以及最新区块距今多久。

为什么不只看节点自己的 eth_syncing：
- 节点"卡住"时（对等节点掉光、共识层断开），eth_syncing 常常还是 false，看起来"已同步"，
  其实高度早就不涨了。充值扫块服务读到的是旧数据，用户的充值迟迟不到账。
- 所以要用"外部视角"判断：和其他节点比高度；看最新区块的时间戳离现在多远（以太坊 12 秒一个 slot）。

用法：
  # 一次性检查，适合手工或 cron，超过阈值退出码为 1
  python3 height_check.py --node lab-eth1=http://127.0.0.1:8545 --node lab-eth2=http://192.168.56.32:8545 \
      --reference public=https://<公共 RPC 地址>
  # 作为 exporter 常驻，Prometheus 抓 :9701/metrics
  python3 height_check.py --serve 9701 --interval 15 --node ... --reference ...

只用 Python 标准库。
"""
from __future__ import annotations

import argparse
import json
import sys
import threading
import time
import urllib.request
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


@dataclass
class Result:
    name: str
    role: str  # local / reference
    url: str
    up: bool = False
    height: int = 0
    block_ts: int = 0
    peers: int = -1
    syncing: bool = False
    chain_id: int = 0
    error: str = ""
    latency_ms: int = 0


def parse_hex(v) -> int:
    if isinstance(v, int):
        return v
    if not isinstance(v, str) or not v.startswith("0x"):
        raise ValueError(f"not a hex quantity: {v!r}")
    return int(v, 16)


def parse_endpoint(spec: str) -> tuple[str, str]:
    if "=" not in spec:
        raise argparse.ArgumentTypeError(f"格式应为 名字=URL：{spec}")
    name, url = spec.split("=", 1)
    if not name or not url.startswith(("http://", "https://")):
        raise argparse.ArgumentTypeError(f"格式应为 名字=http(s)://...：{spec}")
    return name, url


def rpc_batch(url: str, timeout: float) -> list[dict]:
    """一次批量请求拿到 4 个值，减少往返。参考节点不一定支持 net_peerCount，所以单独容错。"""
    body = [
        {"jsonrpc": "2.0", "id": 1, "method": "eth_getBlockByNumber", "params": ["latest", False]},
        {"jsonrpc": "2.0", "id": 2, "method": "eth_syncing", "params": []},
        {"jsonrpc": "2.0", "id": 3, "method": "net_peerCount", "params": []},
        {"jsonrpc": "2.0", "id": 4, "method": "eth_chainId", "params": []},
    ]
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "User-Agent": "height-check/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read())
    if not isinstance(data, list):
        raise ValueError(f"unexpected response: {str(data)[:120]}")
    return data


def interpret(name: str, role: str, url: str, responses: list[dict]) -> Result:
    r = Result(name=name, role=role, url=url)
    by_id = {x.get("id"): x for x in responses if isinstance(x, dict)}
    block = (by_id.get(1) or {}).get("result")
    if not block:
        r.error = str((by_id.get(1) or {}).get("error", "no latest block"))[:120]
        return r
    r.height = parse_hex(block["number"])
    r.block_ts = parse_hex(block["timestamp"])
    r.syncing = bool((by_id.get(2) or {}).get("result", False))
    peers = (by_id.get(3) or {}).get("result")
    r.peers = parse_hex(peers) if peers else -1
    cid = (by_id.get(4) or {}).get("result")
    r.chain_id = parse_hex(cid) if cid else 0
    r.up = True
    return r


def check(name: str, role: str, url: str, timeout: float) -> Result:
    t0 = time.monotonic()
    try:
        r = interpret(name, role, url, rpc_batch(url, timeout))
    except Exception as e:  # noqa: BLE001
        r = Result(name=name, role=role, url=url, error=f"{type(e).__name__}: {e}"[:160])
    r.latency_ms = int((time.monotonic() - t0) * 1000)
    return r


def best_height(results: list[Result]) -> int:
    return max((r.height for r in results if r.up), default=0)


def evaluate(results: list[Result], now: float, max_lag: int, max_age: int, min_peers: int) -> list[str]:
    """返回问题列表，空列表表示健康。只评估自建节点（local），参考节点只用来比较。"""
    problems = []
    best = best_height(results)
    chain_ids = {r.chain_id for r in results if r.up and r.chain_id}
    if len(chain_ids) > 1:
        problems.append(f"节点不在同一条链上：chainId={sorted(chain_ids)}（参考节点地址配错了网络？）")
    for r in results:
        if r.role != "local":
            continue
        if not r.up:
            problems.append(f"{r.name} 不可用：{r.error}")
            continue
        lag = best - r.height
        age = int(now - r.block_ts)
        if lag > max_lag:
            problems.append(f"{r.name} 落后最高高度 {lag} 个块（{r.height} vs {best}）")
        if age > max_age:
            problems.append(f"{r.name} 最新区块是 {age} 秒前的，可能卡住了")
        if r.syncing:
            problems.append(f"{r.name} 正在同步中")
        if 0 <= r.peers < min_peers:
            problems.append(f"{r.name} 对等节点只有 {r.peers} 个")
    if not any(r.up for r in results if r.role == "reference"):
        if any(r.role == "reference" for r in results):
            problems.append("所有参考节点都不可用，高度差结果只在自建节点之间比较")
    return problems


def render_metrics(results: list[Result], now: float) -> str:
    best = best_height(results)
    out = []

    def metric(name, help_, typ, rows):
        out.append(f"# HELP {name} {help_}")
        out.append(f"# TYPE {name} {typ}")
        out.extend(rows)

    def lbl(r: Result) -> str:
        return f'node="{r.name}",role="{r.role}"'

    metric("eth_node_up", "RPC 是否可用", "gauge", [f"eth_node_up{{{lbl(r)}}} {int(r.up)}" for r in results])
    ups = [r for r in results if r.up]
    metric("eth_node_block_height", "最新区块高度", "gauge",
           [f"eth_node_block_height{{{lbl(r)}}} {r.height}" for r in ups])
    metric("eth_node_height_lag_blocks", "落后所有节点中最高高度的块数", "gauge",
           [f"eth_node_height_lag_blocks{{{lbl(r)}}} {best - r.height}" for r in ups])
    metric("eth_node_block_age_seconds", "最新区块时间戳距今秒数", "gauge",
           [f"eth_node_block_age_seconds{{{lbl(r)}}} {max(0, int(now - r.block_ts))}" for r in ups])
    metric("eth_node_syncing", "eth_syncing 是否返回同步中", "gauge",
           [f"eth_node_syncing{{{lbl(r)}}} {int(r.syncing)}" for r in ups])
    metric("eth_node_peers", "对等节点数（参考节点通常不提供）", "gauge",
           [f"eth_node_peers{{{lbl(r)}}} {r.peers}" for r in ups if r.peers >= 0])
    metric("eth_node_rpc_latency_ms", "本次检查的 RPC 耗时", "gauge",
           [f"eth_node_rpc_latency_ms{{{lbl(r)}}} {r.latency_ms}" for r in results])
    return "\n".join(out) + "\n"


def run_all(endpoints: list[tuple[str, str, str]], timeout: float) -> list[Result]:
    results: list[Result] = [None] * len(endpoints)  # type: ignore[list-item]

    def work(i, name, role, url):
        results[i] = check(name, role, url, timeout)

    threads = [threading.Thread(target=work, args=(i, *ep)) for i, ep in enumerate(endpoints)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return results


def serve(port: int, interval: int, endpoints, timeout: float):
    state = {"text": "# no data yet\n"}

    def loop():
        while True:
            res = run_all(endpoints, timeout)
            state["text"] = render_metrics(res, time.time())
            time.sleep(interval)

    threading.Thread(target=loop, daemon=True).start()

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            if self.path not in ("/metrics", "/"):
                self.send_response(404)
                self.end_headers()
                return
            data = state["text"].encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    print(f"height-check exporter listening on :{port}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="以太坊节点区块高度对比")
    p.add_argument("--node", action="append", type=parse_endpoint, default=[], help="自建节点 名字=URL，可多次")
    p.add_argument("--reference", action="append", type=parse_endpoint, default=[], help="参考节点 名字=URL，可多次")
    p.add_argument("--max-lag", type=int, default=5, help="允许落后的块数，默认 5（约 1 分钟）")
    p.add_argument("--max-age", type=int, default=60, help="最新区块最多多少秒前，默认 60")
    p.add_argument("--min-peers", type=int, default=5)
    p.add_argument("--timeout", type=float, default=5.0)
    p.add_argument("--serve", type=int, help="以 exporter 方式运行，监听这个端口")
    p.add_argument("--interval", type=int, default=15)
    args = p.parse_args(argv)
    if not args.node:
        p.error("至少要一个 --node")
    endpoints = [(n, "local", u) for n, u in args.node] + [(n, "reference", u) for n, u in args.reference]
    if args.serve:
        serve(args.serve, args.interval, endpoints, args.timeout)
        return 0
    results = run_all(endpoints, args.timeout)
    now = time.time()
    best = best_height(results)
    for r in results:
        if r.up:
            print(f"{r.name:<14} {r.role:<9} 高度 {r.height:<10} 落后 {best - r.height:<4} "
                  f"区块距今 {int(now - r.block_ts):>4}s  peers {r.peers if r.peers >= 0 else '-':<4} "
                  f"{'同步中' if r.syncing else ''} {r.latency_ms}ms")
        else:
            print(f"{r.name:<14} {r.role:<9} 不可用：{r.error}")
    problems = evaluate(results, now, args.max_lag, args.max_age, args.min_peers)
    for x in problems:
        print(f"[问题] {x}")
    if not problems:
        print("[正常] 所有自建节点高度正常")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
