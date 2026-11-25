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

k6 v2.4.0、metrics-server v0.9.1、KEDA v2.21.1（官方兼容表测试过 Kubernetes 1.34–1.36，还没覆盖课程用的 1.37）。以各项目官方文档为准。

## 验证记录

在 Ubuntu 24.04 容器里真跑通过：

- k6 v2.4.0 用官方 APT 源（DEB822 写法）安装
- `scripts/loadtest-data.sh prepare` → `k6 run -e PROFILE=smoke k6/mall-load.js` → `scripts/loadtest-data.sh cleanup`：mall-api（`cd app && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build`）单实例连 MySQL 8.4，k6 直接压 `http://127.0.0.1:8080`。363 个请求，失败率 0，6 个阈值全部通过；cleanup 删除压测订单 61 条并恢复库存
- 脚本 `shellcheck` + `bash -n` 通过

没有验证：step / stress / soak 三种加压方式（单机容器资源有限，且容量数据要在 K8s 里测才有意义）；`k8s/` 下的 HPA、KEDA、metrics-server、PodMonitor 等所有 K8s 部分（不连集群，只做 YAML 语法检查）；`scripts/watch-scaling.sh` 依赖集群。
