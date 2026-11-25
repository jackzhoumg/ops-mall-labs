"""OpenAI 兼容的 Chat Completions 调用。直接用 httpx 发请求，少一个依赖，超时也更好控制。"""
from __future__ import annotations

import httpx


class LLMError(RuntimeError):
    pass


class ChatClient:
    def __init__(self, base_url: str, api_key: str, model: str, timeout: float, json_mode: bool = False,
                 transport: httpx.BaseTransport | None = None):
        self.url = f"{base_url.rstrip('/')}/chat/completions"
        self.model = model
        self.json_mode = json_mode
        headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        # 总超时 = 连接 5 秒 + 读取 timeout 秒。大模型生成慢，读超时要给够，但不能无限等
        self.http = httpx.Client(timeout=httpx.Timeout(timeout, connect=5.0), headers=headers, transport=transport)

    def chat(self, messages: list[dict]) -> str:
        body = {"model": self.model, "messages": messages, "temperature": 0.1, "max_tokens": 1200}
        if self.json_mode:
            body["response_format"] = {"type": "json_object"}
        try:
            r = self.http.post(self.url, json=body)
        except httpx.HTTPError as e:
            raise LLMError(f"请求失败：{type(e).__name__}") from e
        if r.status_code != 200:
            raise LLMError(f"HTTP {r.status_code}: {r.text[:200]}")
        try:
            return r.json()["choices"][0]["message"]["content"] or ""
        except (KeyError, IndexError, ValueError) as e:
            raise LLMError(f"响应格式不对：{r.text[:200]}") from e
