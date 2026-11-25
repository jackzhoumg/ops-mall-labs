"""发给外部大模型前的脱敏（和 AIOps-1 的规则一致，精简版）。"""
from __future__ import annotations

import re

RULES: list[tuple[re.Pattern, str]] = [
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S), "[私钥已脱敏]"),
    (re.compile(r"(?i)(authorization:\s*bearer\s+)[^\s\"']+"), r"\1***"),
    (re.compile(r"(?i)\b((?:api[_-]?key|access[_-]?key|secret|token|passwd|password|pwd)\s*[:=]\s*)[\"']?[^\s\"',;]+"),
     r"\1***"),
    (re.compile(r"(\b[\w.-]+:)[^@\s/:]+(@tcp\()"), r"\1***\2"),
    (re.compile(r"\bsk-[A-Za-z0-9_\-]{16,}\b"), "sk-***"),
    (re.compile(r"(?<!\d)1[3-9]\d{9}(?!\d)"), "1**********"),
    (re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b"), "[邮箱已脱敏]"),
]


def redact(text: str) -> str:
    for p, r in RULES:
        text = p.sub(r, text)
    return text
