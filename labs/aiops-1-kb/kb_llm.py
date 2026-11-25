"""调用 OpenAI 兼容接口：Embedding 和 Chat。

所有地址、密钥、模型名都从环境变量读，代码里不写死任何厂商：
  KB_EMBED_BASE_URL / KB_EMBED_API_KEY / KB_EMBED_MODEL   向量化接口
  KB_CHAT_BASE_URL  / KB_CHAT_API_KEY  / KB_CHAT_MODEL    对话接口
  向量化和对话可以是两家服务（比如向量化用本地 Ollama，对话用云上大模型），
  没单独配 KB_EMBED_* 时用 KB_CHAT_* 的地址和密钥。
"""
from __future__ import annotations

import os
import time
from dataclasses import dataclass


class ConfigError(RuntimeError):
    pass


@dataclass
class LLMConfig:
    chat_base_url: str
    chat_api_key: str
    chat_model: str
    embed_base_url: str
    embed_api_key: str
    embed_model: str
    embed_batch: int = 10
    timeout: float = 60.0
    temperature: float = 0.1

    @classmethod
    def from_env(cls, env=os.environ) -> "LLMConfig":
        chat_base = env.get("KB_CHAT_BASE_URL", "")
        chat_key = env.get("KB_CHAT_API_KEY", "")
        cfg = cls(
            chat_base_url=chat_base,
            chat_api_key=chat_key,
            chat_model=env.get("KB_CHAT_MODEL", ""),
            embed_base_url=env.get("KB_EMBED_BASE_URL", chat_base),
            embed_api_key=env.get("KB_EMBED_API_KEY", chat_key),
            embed_model=env.get("KB_EMBED_MODEL", ""),
            embed_batch=int(env.get("KB_EMBED_BATCH", "10")),
            timeout=float(env.get("KB_TIMEOUT", "60")),
            temperature=float(env.get("KB_TEMPERATURE", "0.1")),
        )
        return cfg

    def require(self, *, chat: bool, embed: bool):
        missing = []
        if embed:
            missing += [n for n, v in (("KB_EMBED_BASE_URL", self.embed_base_url),
                                       ("KB_EMBED_MODEL", self.embed_model)) if not v]
        if chat:
            missing += [n for n, v in (("KB_CHAT_BASE_URL", self.chat_base_url),
                                       ("KB_CHAT_MODEL", self.chat_model)) if not v]
        if missing:
            raise ConfigError("缺少环境变量：" + ", ".join(missing) + "（参考 .env.example）")


def _client(base_url: str, api_key: str, timeout: float):
    from openai import OpenAI  # 延迟导入：跑单元测试不需要装 openai

    # 本地 Ollama / vLLM 不校验密钥，但 SDK 要求非空，给个占位
    return OpenAI(base_url=base_url, api_key=api_key or "not-needed", timeout=timeout, max_retries=2)


class OpenAICompatLLM:
    """真实实现。测试里用 FakeLLM 代替，接口一样：embed(texts) / chat(messages)。"""

    def __init__(self, cfg: LLMConfig):
        self.cfg = cfg
        self._embed = None
        self._chat = None

    def embed(self, texts: list[str]) -> list[list[float]]:
        if self._embed is None:
            self._embed = _client(self.cfg.embed_base_url, self.cfg.embed_api_key, self.cfg.timeout)
        out: list[list[float]] = []
        # 很多国内服务限制每次请求的条数（常见 10-25 条），分批发
        for i in range(0, len(texts), self.cfg.embed_batch):
            batch = texts[i:i + self.cfg.embed_batch]
            for attempt in range(3):
                try:
                    resp = self._embed.embeddings.create(model=self.cfg.embed_model, input=batch)
                    break
                except Exception:  # noqa: BLE001 限流、网络抖动，退避重试
                    if attempt == 2:
                        raise
                    time.sleep(2 ** attempt)
            out.extend(d.embedding for d in sorted(resp.data, key=lambda d: d.index))
        return out

    def chat(self, messages: list[dict]) -> str:
        if self._chat is None:
            self._chat = _client(self.cfg.chat_base_url, self.cfg.chat_api_key, self.cfg.timeout)
        resp = self._chat.chat.completions.create(
            model=self.cfg.chat_model, messages=messages, temperature=self.cfg.temperature)
        return resp.choices[0].message.content or ""
