#!/usr/bin/env python3
"""mall-api 容量计算器：根据压测得到的单实例容量和业务预估的峰值，算出需要多少个实例。

用法（任意装了 Python 3 的机器）：
  python3 scripts/capacity-calc.py --base-peak-rps 300 --growth 3 --per-instance-rps 180
  python3 scripts/capacity-calc.py --base-peak-rps 300 --growth 3 --per-instance-rps 180 \
      --zones 2 --target-util 0.7 --db-max-connections 500 --markdown

公式（教程“容量模型”一节有推导）：
  预估峰值 = 日常峰值 × 大促倍数
  基础实例数 = ceil(预估峰值 / (单实例容量 × 目标水位))
  冗余后实例数：
    多可用区：挂掉一个区剩下的也要扛住，实例数 × zones / (zones - 1)，再按区数向上取整
    单可用区：N + 1（坏一台不影响）
  数据库连接数 = 实例数 × 每实例连接池上限，要小于 MySQL max_connections 并留余量
"""
import argparse
import math
import sys


def parse_args():
    p = argparse.ArgumentParser(description="mall-api 容量计算器")
    p.add_argument("--base-peak-rps", type=float, required=True, help="日常峰值 RPS（来自监控，取最近 4 周的最大值）")
    p.add_argument("--growth", type=float, default=1.0, help="大促倍数，来自业务预估或去年同期，默认 1")
    p.add_argument("--per-instance-rps", type=float, required=True,
                   help="单实例容量：阶梯压测中满足 SLO（错误率 < 0.1%%、P99 < 500ms）的最高一级 RPS")
    p.add_argument("--target-util", type=float, default=0.7,
                   help="目标水位：平时只让实例跑到容量的多少，默认 0.7，留 30%% 应对突发和预估误差")
    p.add_argument("--zones", type=int, default=1, help="可用区数量，默认 1；>= 2 时按“坏一个区也能扛住”计算")
    p.add_argument("--min-instances", type=int, default=2, help="最少实例数，默认 2")
    p.add_argument("--pool-per-instance", type=int, default=20,
                   help="每实例数据库连接池上限，mall-api 代码里 SetMaxOpenConns(20)")
    p.add_argument("--db-max-connections", type=int, default=151, help="MySQL max_connections，默认值 151")
    p.add_argument("--markdown", action="store_true", help="输出 Markdown 表格，直接贴进容量评估报告")
    a = p.parse_args()
    for name in ("base_peak_rps", "growth", "per_instance_rps"):
        if getattr(a, name) <= 0:
            p.error(f"--{name.replace('_', '-')} 必须大于 0")
    if not 0 < a.target_util <= 1:
        p.error("--target-util 必须在 (0, 1] 之间")
    if a.zones < 1:
        p.error("--zones 至少为 1")
    return a


def calc(a):
    peak = a.base_peak_rps * a.growth
    usable_per_instance = a.per_instance_rps * a.target_util
    base = max(a.min_instances, math.ceil(peak / usable_per_instance))

    if a.zones >= 2:
        # 坏一个区后剩 zones-1 个区，要扛住全部流量
        need = math.ceil(base * a.zones / (a.zones - 1))
        need = math.ceil(need / a.zones) * a.zones  # 每个区实例数相同
        redundancy = f"{a.zones} 个可用区，坏一个区仍能扛住峰值"
    else:
        need = base + 1
        redundancy = "单可用区 N+1"

    db_conns = need * a.pool_per_instance
    db_ratio = db_conns / a.db_max_connections
    # 坏一个区时的实际水位
    survivors = need - (need // a.zones if a.zones >= 2 else 1)
    util_degraded = peak / (survivors * a.per_instance_rps) if survivors > 0 else float("inf")
    util_normal = peak / (need * a.per_instance_rps)

    return {
        "预估峰值 RPS": f"{peak:.0f}（日常峰值 {a.base_peak_rps:.0f} × 大促倍数 {a.growth:g}）",
        "单实例容量 RPS": f"{a.per_instance_rps:.0f}（压测满足 SLO 的最高一级）",
        "单实例可用容量 RPS": f"{usable_per_instance:.0f}（× 目标水位 {a.target_util:g}）",
        "基础实例数": f"{base}",
        "冗余策略": redundancy,
        "建议实例数": f"{need}",
        "正常时水位": f"{util_normal:.0%}",
        "故障时水位": f"{util_degraded:.0%}（坏一个{'区' if a.zones >= 2 else '实例'}后）",
        "数据库连接数": f"{db_conns}（{need} × {a.pool_per_instance}），占 max_connections {a.db_max_connections} 的 {db_ratio:.0%}",
        "_db_ratio": db_ratio,
        "_util_degraded": util_degraded,
        "_need": need,
    }


def main():
    a = parse_args()
    r = calc(a)
    rows = [(k, v) for k, v in r.items() if not k.startswith("_")]
    if a.markdown:
        print("| 项目 | 结果 |")
        print("|---|---|")
        for k, v in rows:
            print(f"| {k} | {v} |")
    else:
        width = max(len(k) for k, _ in rows)
        for k, v in rows:
            print(f"{k:<{width}}  {v}")

    warnings = []
    if r["_db_ratio"] > 0.8:
        warnings.append("数据库连接数超过 max_connections 的 80%：调大 max_connections、减小连接池，"
                        "或者加读写分离 / 连接代理（如 ProxySQL），否则扩容 Pod 会把数据库连接打满")
    if r["_util_degraded"] > 0.9:
        warnings.append("故障时水位超过 90%：冗余不够，再加实例或提高单实例容量")
    if warnings:
        print()
        for w in warnings:
            print(f"警告：{w}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
