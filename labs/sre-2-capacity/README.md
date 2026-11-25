# SRE-2 容量规划与压测

对应教程：《DevOps 运维实战》进阶-SRE / SRE-2-容量规划与压测。

## 文件

| 文件 | 用途 |
|---|---|
| `k6/mall-load.js` | k6 混合场景脚本：浏览 90% + 下单 10%，按到达速率加压；`PROFILE=smoke/step/stress/soak` |
| `k8s/mall-api-resources-patch.yaml` | 给 mall-api 设置 requests / limits（HPA 的前提） |
| `k8s/metrics-server-insecure-tls.json` | kubeadm 实验集群里 metrics-server 连不上 kubelet 时的补丁 |
| `k8s/hpa-cpu.yaml` | 思路一：按 CPU 利用率扩缩容 |
| `k8s/keda-scaledobject.yaml` | 思路二：KEDA + Prometheus，按每 Pod RPS 扩缩容（和思路一二选一） |
| `k8s/envoy-podmonitor.yaml` | 抓取 Envoy 网关代理指标（Lab 09 没抓，压测前加上） |
| `promql/bottleneck-queries.md` | 网关、mall-api、MySQL、Redis、节点各层的瓶颈定位 PromQL |
| `scripts/loadtest-data.sh` | lab-db1 上压测前调高库存、压测后删订单恢复库存 |
| `scripts/watch-scaling.sh` | 压测时盯 HPA、Pod 数、CPU |
| `scripts/capacity-calc.py` | 容量计算器：峰值、单实例容量、水位、冗余 → 实例数、数据库连接数 |
| `report/capacity-report-template.md` | 容量评估报告模板 |

## 校验

```bash
k6 inspect -e PROFILE=step k6/mall-load.js     # 检查脚本能解析、看算出来的场景参数
k6 run -e PROFILE=smoke -e BASE_URL=http://mall.lab.local k6/mall-load.js
python3 scripts/capacity-calc.py --base-peak-rps 300 --growth 3 --per-instance-rps 180
```

## 写作时版本

k6 v2.4.0、metrics-server v0.9.1、KEDA v2.21.1（官方说明测试过 Kubernetes 1.34–1.36）。以各项目官方文档为准。
