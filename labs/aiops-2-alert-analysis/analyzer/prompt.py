"""提示词拼装和模型输出解析。

提示词四要素：角色、上下文、输出格式（JSON）、禁止事项（不编造、不给危险命令）。
模型输出不可信：解析失败、字段缺失、命令有风险，都要在这里兜住。
"""
from __future__ import annotations

import json
import re

from .aggregator import AlertGroup
from .redact import redact

SYSTEM_PROMPT = """你是某电商公司的资深 SRE，正在值班。系统是 ops-mall 商城：mall-api（Go，跑在 K8s 的 mall 命名空间）、
MySQL 和 Redis 跑在 K8s 外的虚拟机 lab-db1（192.168.56.13），入口是 Envoy Gateway。
你的任务：根据【告警】和【上下文】判断可能原因，给出排查步骤和命令。

必须遵守：
1. 只根据给出的数据推理。每条原因都要在 evidence 里写出依据的具体数据（指标值、日志、事件）；没有依据就不要写这条原因。
2. 数据不足以判断时，summary 写"数据不足以判断"，possible_causes 可以为空，steps 写需要补充看什么。
3. 不要编造不存在的指标名、日志内容、Pod 名或 IP。
4. 命令优先给只读的（get / describe / logs / top / SHOW / curl 查询）。会改变系统状态的命令（重启、扩缩容、回滚、删除、kill、改配置）
   risk 必须填 "change"，并且 need_human 填 true。绝不给出删除数据、删除命名空间、DROP、rm -rf 这类命令。
5. 上下文里的"查询失败"表示数据没拿到，不代表没有问题。
6. 只输出一个 JSON 对象，不要输出 JSON 以外的任何文字，不要用 Markdown 代码块包起来。

JSON 格式：
{
  "summary": "一句话结论，不超过 60 字",
  "possible_causes": [{"cause": "原因", "evidence": "依据的数据", "confidence": "high|medium|low"}],
  "steps": ["排查步骤 1", "排查步骤 2"],
  "commands": [{"cmd": "命令", "where": "在哪台机器执行", "risk": "read-only|change"}],
  "need_human": true
}
possible_causes 最多 3 条，按可能性从高到低；steps 最多 5 条；commands 最多 5 条。"""


def render_alert(group: AlertGroup) -> str:
    lines = [f"告警名：{group.alertname}", f"级别：{group.severity}", f"命名空间：{group.namespace or '-'}",
             f"开始时间（UTC）：{group.starts_at}", f"同组告警数：{len(group.alerts)}"]
    ann = group.annotations
    if ann.get("summary"):
        lines.append(f"摘要：{ann['summary']}")
    if ann.get("description"):
        lines.append(f"描述：{ann['description']}")
    labels = {k: v for k, v in group.labels.items() if k not in ("alertname", "severity", "namespace")}
    if labels:
        lines.append("标签：" + ", ".join(f"{k}={v}" for k, v in sorted(labels.items())))
    for a in group.alerts[1:5]:
        extra = {k: v for k, v in a.get("labels", {}).items() if k not in group.labels or group.labels[k] != v}
        if extra:
            lines.append("其他实例：" + ", ".join(f"{k}={v}" for k, v in sorted(extra.items())))
    return "\n".join(lines)


def render_context(ctx: dict, max_chars: int) -> str:
    """三个数据源按固定顺序拼接；超长时按比例截断每一段，保证每个数据源都有内容。"""
    sections = [("Prometheus 指标（近 15 分钟，每条序列的最小/最大/最新值）", ctx.get("prometheus", [])),
                ("Loki 日志（ERROR/WARN，按消息去重计数）", ctx.get("loki", [])),
                ("Kubernetes", ctx.get("kubernetes", []))]
    per = max(200, max_chars // len(sections))
    out = []
    for title, lines in sections:
        text = "\n".join(lines) if lines else "（无）"
        if len(text) > per:
            text = text[:per] + "\n...(已截断)"
        out.append(f"## {title}\n{text}")
    return "\n\n".join(out)


def build_messages(group: AlertGroup, ctx: dict, max_chars: int = 8000) -> list[dict]:
    user = f"【告警】\n{render_alert(group)}\n\n【上下文】\n{render_context(ctx, max_chars)}"
    return [{"role": "system", "content": SYSTEM_PROMPT}, {"role": "user", "content": redact(user)}]


# ---------------------------------------------------------------- 输出解析

DANGEROUS = re.compile(
    r"(\brm\s+-[a-z]*r|\bdrop\s+(table|database)|\btruncate\b|\bdelete\b|\bkill\b|\breboot\b|\bshutdown\b|"
    r"\brollout\s+(undo|restart)|\bscale\b|\bset\s+(env|image)\b|\bedit\b|\bapply\b|\bpatch\b|\bdrain\b|\bcordon\b|"
    r"\bsystemctl\s+(restart|stop)|\bpurge\b|\bflushall\b|\bflushdb\b)",
    re.I,
)
FORBIDDEN = re.compile(r"(\brm\s+-[a-z]*rf?\s+/|\bdrop\s+(table|database)|\bdelete\s+(ns|namespace)\b|\bflushall\b|"
                       r"\bmkfs\b|\bdd\s+if=)", re.I)


def extract_json(text: str) -> dict | None:
    """模型经常不听话：外面包 ```json、前面加一句"好的"。取第一个 { 到最后一个 } 之间的内容解析。"""
    if not text:
        return None
    text = text.strip()
    fence = re.search(r"```(?:json)?\s*(\{.*\})\s*```", text, re.S)
    if fence:
        text = fence.group(1)
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        obj = json.loads(text[start:end + 1])
    except json.JSONDecodeError:
        return None
    return obj if isinstance(obj, dict) else None


def _s(v, limit=300) -> str:
    return str(v).strip()[:limit] if v is not None else ""


def normalize(obj: dict) -> dict | None:
    """校验并规整模型输出；summary 都没有就当解析失败。命令风险由本地规则复核，不信模型自报。"""
    if not obj or not _s(obj.get("summary")):
        return None
    causes = []
    for c in (obj.get("possible_causes") or [])[:3]:
        if isinstance(c, dict) and _s(c.get("cause")):
            conf = _s(c.get("confidence")).lower()
            causes.append({"cause": _s(c.get("cause")), "evidence": _s(c.get("evidence")),
                           "confidence": conf if conf in ("high", "medium", "low") else "low"})
    steps = [_s(x) for x in (obj.get("steps") or [])[:5] if _s(x)]
    commands, need_human = [], bool(obj.get("need_human", False))
    for c in (obj.get("commands") or [])[:5]:
        if isinstance(c, str):
            c = {"cmd": c}
        if not isinstance(c, dict) or not _s(c.get("cmd")):
            continue
        cmd = _s(c.get("cmd"), 500)
        if FORBIDDEN.search(cmd):
            continue  # 高危命令直接丢弃，不推送给人
        risk = "change" if DANGEROUS.search(cmd) or _s(c.get("risk")) == "change" else "read-only"
        need_human = need_human or risk == "change"
        commands.append({"cmd": cmd, "where": _s(c.get("where"), 60) or "-", "risk": risk})
    return {"summary": _s(obj.get("summary"), 120), "possible_causes": causes, "steps": steps,
            "commands": commands, "need_human": need_human}


def parse_output(text: str) -> dict | None:
    return normalize(extract_json(text))
