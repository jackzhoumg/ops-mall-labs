# SRE-4 故障演练与事故管理

对应教程：《DevOps 运维实战》进阶 SRE-4 故障演练与事故管理

前提：Lab 05-06 的 K8s 集群和 mall 命名空间里的 mall-api / mall-web 已经跑起来，Lab 09 的 Prometheus / Grafana / Alertmanager 可用。
所有 kubectl 命令默认在 k8s-master 上执行。

## 文件

| 文件 | 用途 |
|---|---|
| `install/values-chaos-mesh.yaml` | Chaos Mesh Helm values：只允许在 mall 命名空间做实验、containerd 运行时、Dashboard 安全模式 |
| `install/dashboard-rbac.yaml` | Chaos Dashboard 登录账号，权限只限 mall 命名空间 |
| `experiments/01-pod-kill.yaml` | PodChaos：随机杀 1 个 mall-api Pod |
| `experiments/02-network-delay-mysql.yaml` | NetworkChaos：mall-api 到 lab-db1 延迟 200ms，5 分钟 |
| `experiments/03-network-loss-mysql.yaml` | NetworkChaos：1 个 mall-api Pod 到 lab-db1 丢包 30%，3 分钟 |
| `experiments/04-stress-cpu.yaml` | StressChaos：CPU 压力 |
| `experiments/05-stress-memory.yaml` | StressChaos：内存压力 |
| `experiments/06-schedule-pod-kill.yaml` | Schedule：工作日定时杀 Pod（常态化演练，选做） |
| `k8s/mall-api-pdb.yaml` | mall-api 的 PodDisruptionBudget |
| `k8s/mall-api-probe-fragile.yaml` | 模拟演练用：把就绪探针改成“很敏感”的写法 |
| `k8s/mall-api-probe-mitigate.yaml` | 模拟演练止损用：就绪探针临时改查 /healthz |
| `k8s/mall-api-probe-patch.yaml` | 复盘改进项：就绪探针容忍短时抖动 |
| `k8s/prometheusrule-drill.yaml` | 告警规则：可用副本不足一半（P1）、5xx 比例、P95 延迟 |
| `scripts/steady-state.sh` | 稳态探测：持续请求商城，输出成功率和 P50/P95 |
| `scripts/preflight-check.sh` | 演练前自动检查 |
| `scripts/abort.sh` | 紧急停止：删除 mall 命名空间里所有混沌实验 |
| `scripts/debug-faults.sh` | 调用 mall-api 故障接口（slow / error / cpu / leak，需要 MALL_DEBUG=true） |
| `scripts/gameday-db-delay.sh` | 模拟事故演练：在 lab-db1 上用 tc 给 MySQL / Redis 回包加延迟，带自动撤销 |
| `templates/drill-checklist.md` | 演练前检查清单 |
| `templates/incident-levels.md` | 事故分级 P1-P4 与响应时限 |
| `templates/oncall-handbook.md` | On-call 值班手册：排班、升级、交接、事故角色 |
| `templates/comms-templates.md` | 对内 / 对外沟通模板 |
| `templates/postmortem-template.md` | 无责复盘文档模板 |
| `templates/postmortem-example-gameday.md` | 用模拟演练填好的复盘示例 |

## 快速开始

```bash
# k8s-master
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm install chaos-mesh chaos-mesh/chaos-mesh -n chaos-mesh --create-namespace \
  --version 2.8.8 -f install/values-chaos-mesh.yaml
kubectl apply -f k8s/mall-api-pdb.yaml
bash scripts/preflight-check.sh

# 另开一个终端跑稳态探测
bash scripts/steady-state.sh

kubectl apply -f experiments/01-pod-kill.yaml
```

## 清理

```bash
bash scripts/abort.sh
kubectl -n mall set env deployment/mall-api MALL_DEBUG-      # 去掉故障接口开关
helm uninstall chaos-mesh -n chaos-mesh                      # 不再需要 Chaos Mesh 时
```

## 写作时版本

Chaos Mesh 2.8.8（Helm Chart 2.8.8），Kubernetes v1.37，节点系统 Ubuntu Server 24.04 LTS。以官方最新文档为准。

## 验证记录

在 Ubuntu 24.04 容器里真跑通过：

- `scripts/steady-state.sh`：对容器里的 mall-api 探测（含 `ORDER=1` 下单），稳态成立时退出码 0；对一个不存在的地址探测，输出“稳态被打破”、退出码 1
- `scripts/gameday-db-delay.sh`：参数检查、找不到网卡时的提示、加载内核模块失败时的提示和退出码
- `k8s/prometheusrule-drill.yaml` 的规则用 promtool v3.16.0 `check rules` 通过
- 脚本 `shellcheck` + `bash -n` 通过

没有验证：

- `gameday-db-delay.sh start / status / stop` 真正注入 tc netem 延迟：验证机的宿主机内核没有加载 `sch_netem` / `sch_prio`，容器里执行 tc 会触发宿主机自动加载内核模块，属于改动宿主机，按验证规则没有做。已确认 Ubuntu 24.04 generic 内核（6.8.0-151）的 `linux-modules` 包里自带这两个模块。需要讲师在允许加载模块的机器上补测：`sudo modprobe sch_netem sch_prio` 后执行 `start`、`status`、`stop`，并确认 `systemd-run` 的自动撤销定时器生效
- Chaos Mesh 安装、`experiments/`、`k8s/`、`scripts/abort.sh`、`scripts/preflight-check.sh`、`scripts/debug-faults.sh`：需要 K8s 集群，只做了 YAML 语法检查
