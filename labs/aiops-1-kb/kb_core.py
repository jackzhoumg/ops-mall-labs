"""运维知识库的纯逻辑部分：读文档、切分、相似度、关键词打分、脱敏、拼提示词。

这里的函数都不联网、不读环境变量，方便写单元测试。
联网部分（调 Embedding / Chat 接口）在 kb_llm.py，存储在 kb_store.py，命令行入口在 kb.py。
"""
from __future__ import annotations

import hashlib
import math
import re
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------- 数据结构


@dataclass
class Chunk:
    """一个文档片段。source + heading 用来在回答里标注引用来源。"""

    source: str  # 相对路径，如 runbooks/01-nginx-502.md
    heading: str  # 片段所在的标题路径，如 "Nginx 502 排查 > 3. 排查步骤"
    text: str
    index: int = 0  # 同一文档里的第几个片段
    meta: dict = field(default_factory=dict)

    @property
    def chunk_id(self) -> str:
        return f"{self.source}#{self.index}"


# ---------------------------------------------------------------- 读文档

FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.S)


def parse_frontmatter(text: str) -> tuple[dict, str]:
    """解析简单的 YAML frontmatter（只支持 key: value 一行一个），返回 (meta, 正文)。

    不引入 PyYAML：Runbook 的 frontmatter 只放 title / tags / owner / updated 这类简单字段。
    """
    m = FRONTMATTER_RE.match(text)
    if not m:
        return {}, text
    meta = {}
    for line in m.group(1).splitlines():
        if ":" not in line or line.startswith(" "):
            continue
        k, v = line.split(":", 1)
        meta[k.strip()] = v.strip().strip('"').strip("'")
    return meta, text[m.end():]


def file_sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def iter_markdown_files(root: Path):
    for p in sorted(root.rglob("*.md")):
        if p.name.upper() == "README.MD":
            continue
        yield p


# ---------------------------------------------------------------- 切分

HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")
FENCE_RE = re.compile(r"^(```|~~~)")


def split_sections(body: str) -> list[tuple[str, str]]:
    """按 Markdown 标题切成小节，返回 [(标题路径, 小节正文)]。

    代码块里的 # 不当标题（shell 注释很常见）。标题路径保留上级标题，
    例如 "MySQL 主从延迟 > 排查步骤"，这样检索到的片段即使脱离上下文也知道在讲什么。
    """
    sections: list[tuple[str, list[str]]] = []
    stack: list[tuple[int, str]] = []
    current: list[str] = []
    current_path = ""
    in_fence = False

    def flush():
        text = "\n".join(current).strip()
        if text:
            sections.append((current_path, text))

    for line in body.splitlines():
        if FENCE_RE.match(line.strip()):
            in_fence = not in_fence
            current.append(line)
            continue
        m = None if in_fence else HEADING_RE.match(line)
        if m:
            flush()
            current = []
            level, title = len(m.group(1)), m.group(2).strip()
            while stack and stack[-1][0] >= level:
                stack.pop()
            stack.append((level, title))
            current_path = " > ".join(t for _, t in stack)
            continue
        current.append(line)
    flush()
    return [(p, t) for p, t in sections]


def split_long_text(text: str, max_chars: int, overlap: int) -> list[str]:
    """小节太长时按段落再切，段落还太长就硬切。相邻片段重叠 overlap 个字符，避免一句话被切成两半后都检索不到。"""
    if max_chars <= 0:
        raise ValueError("max_chars must be > 0")
    if overlap < 0 or overlap >= max_chars:
        raise ValueError("overlap must be >= 0 and < max_chars")
    if len(text) <= max_chars:
        return [text]

    # 先按空行分段，但不能把代码块从中间拆开
    paras: list[str] = []
    buf: list[str] = []
    in_fence = False
    for line in text.splitlines():
        if FENCE_RE.match(line.strip()):
            in_fence = not in_fence
        if not line.strip() and not in_fence:
            if buf:
                paras.append("\n".join(buf))
                buf = []
            continue
        buf.append(line)
    if buf:
        paras.append("\n".join(buf))

    pieces: list[str] = []
    cur = ""
    for para in paras:
        candidate = f"{cur}\n\n{para}" if cur else para
        if len(candidate) <= max_chars:
            cur = candidate
            continue
        if cur:
            pieces.append(cur)
        if len(para) <= max_chars:
            cur = para
        else:
            step = max_chars - overlap
            for i in range(0, len(para), step):
                pieces.append(para[i:i + max_chars])
                if i + max_chars >= len(para):
                    break
            cur = ""
    if cur:
        pieces.append(cur)

    if overlap and len(pieces) > 1:
        with_overlap = [pieces[0]]
        for prev, nxt in zip(pieces, pieces[1:]):
            tail = prev[-overlap:]
            with_overlap.append(nxt if nxt.startswith(tail) else f"{tail}\n{nxt}")
        pieces = with_overlap
    return pieces


def chunk_document(source: str, text: str, max_chars: int = 800, overlap: int = 100) -> list[Chunk]:
    """一篇文档 → 若干片段。每个片段正文前加上 "文档标题 / 小节标题"，向量里带上主题信息，召回更准。"""
    meta, body = parse_frontmatter(text)
    title = meta.get("title", "")
    chunks: list[Chunk] = []
    for heading, section in split_sections(body):
        for piece in split_long_text(section, max_chars, overlap):
            header = heading or title
            if title and not header.startswith(title):
                header = f"{title} > {header}" if header else title
            chunks.append(Chunk(source=source, heading=header, text=piece, index=len(chunks), meta=meta))
    return chunks


def embed_text(chunk: Chunk) -> str:
    """送去向量化的文本 = 标题路径 + 正文。"""
    return f"{chunk.heading}\n{chunk.text}" if chunk.heading else chunk.text


# ---------------------------------------------------------------- 相似度


def cosine(a: list[float], b: list[float]) -> float:
    if len(a) != len(b):
        raise ValueError(f"vector dim mismatch: {len(a)} vs {len(b)}")
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


TOKEN_RE = re.compile(r"[A-Za-z][A-Za-z0-9_.\-]*[A-Za-z0-9]|[0-9]{3,}|[\u4e00-\u9fff]+")


def keyword_tokens(text: str) -> set[str]:
    """关键词切词：英文 / 数字串整词，中文按两字一组（不装分词库也能用）。

    运维问题里 502、CrashLoopBackOff、Seconds_Behind_Source 这类词很关键，
    纯向量检索有时会把它们"语义化"掉，加一点关键词打分能补上。
    """
    tokens: set[str] = set()
    for t in TOKEN_RE.findall(text):
        if "\u4e00" <= t[0] <= "\u9fff":
            if len(t) == 1:
                tokens.add(t)
            tokens.update(t[i:i + 2] for i in range(len(t) - 1))
        else:
            tokens.add(t.lower())
    return tokens


def keyword_score(query: str, text: str) -> float:
    q = keyword_tokens(query)
    if not q:
        return 0.0
    d = keyword_tokens(text)
    return len(q & d) / len(q)


def rank(query: str, query_vec: list[float], items: list[tuple[Chunk, list[float]]],
         top_k: int = 4, keyword_weight: float = 0.2) -> list[tuple[Chunk, float]]:
    """混合打分：score = (1-w) * 向量余弦 + w * 关键词命中率，取前 top_k。"""
    scored = []
    for chunk, vec in items:
        s = (1 - keyword_weight) * cosine(query_vec, vec)
        if keyword_weight:
            s += keyword_weight * keyword_score(query, embed_text(chunk))
        scored.append((chunk, s))
    scored.sort(key=lambda x: x[1], reverse=True)
    return scored[:top_k]


# ---------------------------------------------------------------- 脱敏

REDACT_RULES: list[tuple[re.Pattern, str]] = [
    # 私钥块
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S), "[私钥已脱敏]"),
    # Authorization: Bearer xxx / api_key=xxx / token: xxx / password=xxx / secret: xxx
    (re.compile(r"(?i)(authorization:\s*bearer\s+)[^\s\"']+"), r"\1***"),
    (re.compile(r"(?i)\b((?:api[_-]?key|access[_-]?key|secret|token|passwd|password|pwd)\s*[:=]\s*)[\"']?[^\s\"',;]+"), r"\1***"),
    # mysql -pXXXX（-p 后紧跟密码）
    (re.compile(r"(\bmysql\b[^\n]*?\s-p)(?!\s)[^\s]+"), r"\1***"),
    # DSN 里的密码 user:pass@tcp(...)
    (re.compile(r"(\b[\w.-]+:)[^@\s/:]+(@tcp\()"), r"\1***\2"),
    # 常见云厂商 AK 格式、sk- 开头的 API Key
    (re.compile(r"\bsk-[A-Za-z0-9_\-]{16,}\b"), "sk-***"),
    (re.compile(r"\bLTAI[A-Za-z0-9]{12,}\b"), "LTAI***"),
    (re.compile(r"\bAKIA[A-Z0-9]{16}\b"), "AKIA***"),
    # 手机号、身份证号
    (re.compile(r"(?<!\d)1[3-9]\d{9}(?!\d)"), "1**********"),
    (re.compile(r"(?<!\d)\d{17}[\dXx](?!\d)"), "[身份证号已脱敏]"),
    # 邮箱
    (re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b"), "[邮箱已脱敏]"),
]


def redact(text: str) -> str:
    """发给外部大模型之前做一遍脱敏。规则是兜底，不能代替"敏感文档不进知识库"。"""
    for pattern, repl in REDACT_RULES:
        text = pattern.sub(repl, text)
    return text


# ---------------------------------------------------------------- 拼提示词

SYSTEM_PROMPT = """你是某电商公司运维团队的值班助手，负责回答 ops-mall 商城系统的运维问题。
规则：
1. 只根据【参考资料】回答。资料里没有的内容，直接说"知识库里没有找到相关内容"，不要编造命令、参数、IP 或结论。
2. 回答先给结论，再给排查步骤；命令放在代码块里，并说明在哪台机器执行。
3. 每一条关键结论后面用 [编号] 标注出自哪份资料，例如 [1]、[2]。
4. 涉及删除数据、重启数据库、切换主从等高风险操作，提醒先确认影响范围并按变更流程执行。
5. 用简体中文回答，简洁，不超过 400 字（命令不计）。"""


def build_messages(question: str, hits: list[tuple[Chunk, float]], max_context_chars: int = 6000) -> list[dict]:
    """拼成 OpenAI Chat 格式的 messages。参考资料编号从 1 开始，和回答里的 [n] 对应。"""
    parts = []
    used = 0
    for i, (chunk, score) in enumerate(hits, 1):
        block = f"[{i}] 来源：{chunk.source}（{chunk.heading}）\n{chunk.text}"
        if used + len(block) > max_context_chars and parts:
            break
        parts.append(block)
        used += len(block)
    context = "\n\n---\n\n".join(parts) if parts else "（无）"
    user = f"【参考资料】\n{context}\n\n【问题】\n{question}"
    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": redact(user)},
    ]


def format_sources(hits: list[tuple[Chunk, float]]) -> str:
    lines = []
    for i, (chunk, score) in enumerate(hits, 1):
        lines.append(f"[{i}] {chunk.source} | {chunk.heading} | 相似度 {score:.3f}")
    return "\n".join(lines)


NOT_FOUND_ANSWER = "知识库里没有找到相关内容。建议：换个说法再问，或者联系值班负责人，并在处理完后把经验补充进 Runbook。"


def should_answer(hits: list[tuple[Chunk, float]], min_score: float) -> bool:
    """最相关片段的分数低于阈值，就不调大模型，直接回答"没找到"。这是防幻觉最便宜的一道闸。"""
    return bool(hits) and hits[0][1] >= min_score


# ---------------------------------------------------------------- 评估


def recall_at_k(results: list[tuple[str, list[str]]]) -> float:
    """results: [(期望命中的文档, 实际检索到的文档列表)]，返回命中比例。"""
    if not results:
        return 0.0
    hit = sum(1 for expected, got in results if expected in got)
    return hit / len(results)
