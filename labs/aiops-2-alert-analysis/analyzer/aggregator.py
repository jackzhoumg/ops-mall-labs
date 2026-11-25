"""降噪：把一次 webhook 里的告警按"告警名 + 命名空间 + 级别"分组，同一组在冷却时间内只分析一次。

Alertmanager 自己已经做了 group_by / group_interval / repeat_interval，为什么这里还要再做一层：
- 一个告警组每 group_interval（5 分钟）有变化就会再推一次，每次都调大模型又慢又费钱；
- repeat_interval 到了也会重推，内容基本没变，没必要重新分析；
- 多条子路由都 continue 到分析服务时，同一告警可能被推好几次。
冷却状态存在内存里，所以 Deployment 只能 1 个副本；要多副本就把状态放到 Redis。
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field


@dataclass
class AlertGroup:
    key: str
    alertname: str
    namespace: str
    severity: str
    alerts: list = field(default_factory=list)  # 原始 alert 字典

    @property
    def labels(self) -> dict:
        return self.alerts[0].get("labels", {}) if self.alerts else {}

    @property
    def annotations(self) -> dict:
        return self.alerts[0].get("annotations", {}) if self.alerts else {}

    @property
    def starts_at(self) -> str:
        return min((a.get("startsAt", "") for a in self.alerts), default="")


def group_key(labels: dict) -> str:
    return "|".join([labels.get("alertname", "unknown"), labels.get("namespace", ""), labels.get("severity", "")])


def group_alerts(payload: dict, only_status: str = "firing") -> list[AlertGroup]:
    """Alertmanager webhook（version 4）→ 分组。只要指定状态的告警（默认只分析 firing）。"""
    groups: dict[str, AlertGroup] = {}
    for alert in payload.get("alerts", []) or []:
        if alert.get("status") != only_status:
            continue
        labels = alert.get("labels", {}) or {}
        key = group_key(labels)
        if key not in groups:
            groups[key] = AlertGroup(key=key, alertname=labels.get("alertname", "unknown"),
                                     namespace=labels.get("namespace", ""), severity=labels.get("severity", ""))
        groups[key].alerts.append(alert)
    return list(groups.values())


class Cooldown:
    def __init__(self, seconds: int, clock=time.monotonic):
        self.seconds = seconds
        self.clock = clock
        self._last: dict[str, float] = {}
        self.suppressed: dict[str, int] = {}

    def allow(self, key: str) -> bool:
        """冷却期内返回 False 并记一次"被压掉"；否则记录时间返回 True。"""
        now = self.clock()
        last = self._last.get(key)
        if last is not None and now - last < self.seconds:
            self.suppressed[key] = self.suppressed.get(key, 0) + 1
            return False
        self._last[key] = now
        return True

    def reset(self, key: str):
        """告警恢复后清掉冷却，下次再触发就是新的一次故障，要重新分析。"""
        self._last.pop(key, None)
        self.suppressed.pop(key, None)

    def gc(self):
        now = self.clock()
        for k in [k for k, t in self._last.items() if now - t >= self.seconds]:
            self._last.pop(k, None)
