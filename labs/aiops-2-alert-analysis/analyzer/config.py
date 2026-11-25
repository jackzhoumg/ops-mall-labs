"""配置：全部来自环境变量（K8s 里由 ConfigMap + Secret 注入）。"""
from __future__ import annotations

import os
from dataclasses import dataclass


def _bool(v: str) -> bool:
    return v.strip().lower() in ("1", "true", "yes", "on")


@dataclass
class Settings:
    # 数据源
    prom_url: str = "http://kube-prometheus-stack-prometheus.monitoring.svc:9090"
    loki_url: str = "http://loki-gateway.logging.svc"
    # ${namespace} 会被替换成告警的 namespace 标签；标签名要和 Lab 10 日志采集打的标签一致
    loki_selector: str = '{namespace="${namespace}", container="mall-api"}'
    loki_tenant: str = ""  # Loki 开了多租户时填 X-Scope-OrgID
    k8s_enabled: bool = True
    k8s_label_selector: str = "app.kubernetes.io/name=mall-api"
    lookback_minutes: int = 15
    source_timeout: float = 5.0
    # 大模型（OpenAI 兼容接口）
    llm_base_url: str = ""
    llm_api_key: str = ""
    llm_model: str = ""
    llm_timeout: float = 30.0
    llm_json_mode: bool = False  # 服务支持 response_format={"type":"json_object"} 时打开
    max_context_chars: int = 8000
    # 降噪
    cooldown_seconds: int = 1800
    analyze_severities: tuple = ("critical", "warning")
    # 通知
    wecom_webhook: str = ""
    dingtalk_webhook: str = ""
    dingtalk_secret: str = ""
    feedback_base_url: str = ""  # 例如 http://alert-analyzer.lab.local，留空则消息里不带反馈链接
    # 存储
    db_path: str = "/data/analyzer.db"

    @classmethod
    def from_env(cls, env=os.environ) -> "Settings":
        s = cls()
        s.prom_url = env.get("PROM_URL", s.prom_url).rstrip("/")
        s.loki_url = env.get("LOKI_URL", s.loki_url).rstrip("/")
        s.loki_selector = env.get("LOKI_SELECTOR", s.loki_selector)
        s.loki_tenant = env.get("LOKI_TENANT", "")
        s.k8s_enabled = _bool(env.get("K8S_ENABLED", "true"))
        s.k8s_label_selector = env.get("K8S_LABEL_SELECTOR", s.k8s_label_selector)
        s.lookback_minutes = int(env.get("LOOKBACK_MINUTES", s.lookback_minutes))
        s.source_timeout = float(env.get("SOURCE_TIMEOUT", s.source_timeout))
        s.llm_base_url = env.get("LLM_BASE_URL", "").rstrip("/")
        s.llm_api_key = env.get("LLM_API_KEY", "")
        s.llm_model = env.get("LLM_MODEL", "")
        s.llm_timeout = float(env.get("LLM_TIMEOUT", s.llm_timeout))
        s.llm_json_mode = _bool(env.get("LLM_JSON_MODE", "false"))
        s.max_context_chars = int(env.get("MAX_CONTEXT_CHARS", s.max_context_chars))
        s.cooldown_seconds = int(env.get("COOLDOWN_SECONDS", s.cooldown_seconds))
        sev = env.get("ANALYZE_SEVERITIES", ",".join(s.analyze_severities))
        s.analyze_severities = tuple(x.strip() for x in sev.split(",") if x.strip())
        s.wecom_webhook = env.get("WECOM_WEBHOOK", "")
        s.dingtalk_webhook = env.get("DINGTALK_WEBHOOK", "")
        s.dingtalk_secret = env.get("DINGTALK_SECRET", "")
        s.feedback_base_url = env.get("FEEDBACK_BASE_URL", "").rstrip("/")
        s.db_path = env.get("DB_PATH", s.db_path)
        return s

    @property
    def llm_enabled(self) -> bool:
        return bool(self.llm_base_url and self.llm_model)
