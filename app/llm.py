import asyncio
import logging

from openai import AsyncOpenAI

from app.chunking import split_into_chunks
from app.config import settings

log = logging.getLogger(__name__)

OPENAI_CALL_TIMEOUT_SECONDS = 60.0

_client: AsyncOpenAI | None = None


def _get_client() -> AsyncOpenAI:
    global _client
    if _client is None:
        if not settings.openai_api_key:
            raise RuntimeError(
                "OPENAI_API_KEY is not configured. Set it in ai-worker/.env."
            )

        # OpenRouter requires these optional headers; harmless on api.openai.com.
        default_headers = {}
        if "openrouter.ai" in settings.openai_base_url:
            default_headers["HTTP-Referer"] = "http://localhost:3000"
            default_headers["X-Title"] = settings.openai_app_title

        _client = AsyncOpenAI(
            api_key=settings.openai_api_key,
            base_url=settings.openai_base_url,
            timeout=OPENAI_CALL_TIMEOUT_SECONDS,
            default_headers=default_headers or None,
        )
    return _client


SUMMARIZE_SYSTEM_PROMPT = (
    "You are a concise note-summarization assistant. "
    "Given a personal note, produce a faithful 2-4 sentence summary capturing the key points and any action items. "
    "Do not invent facts, do not include preamble, return only the summary text."
)

CHUNK_SYSTEM_PROMPT = (
    "You are summarizing one section of a longer note. "
    "Produce a faithful 1-3 sentence summary of just this section. "
    "Do not add preamble, return only the summary text."
)

REDUCE_SYSTEM_PROMPT = (
    "You are given numbered partial summaries from sequential sections of a single note. "
    "Combine them into one cohesive 3-5 sentence summary of the whole note, "
    "preserving key points and action items in order. "
    "Do not add preamble, return only the summary text."
)


async def summarize_text(title: str | None, content: str) -> tuple[str, str]:
    if len(content) <= settings.summary_chunk_threshold_chars:
        summary = await _call_llm(SUMMARIZE_SYSTEM_PROMPT, _build_titled(title, content))
        return summary, settings.openai_model

    chunks = split_into_chunks(content, settings.summary_chunk_size_chars)
    log.info("summarizing %d chunks in parallel (content=%d chars)", len(chunks), len(content))

    semaphore = asyncio.Semaphore(settings.summary_max_concurrent_chunks)

    async def summarize_one(chunk: str) -> str:
        async with semaphore:
            return await _call_llm(CHUNK_SYSTEM_PROMPT, chunk)

    chunk_summaries = await asyncio.gather(*(summarize_one(c) for c in chunks))

    joined = "\n\n".join(
        f"Section {i + 1}: {summary}" for i, summary in enumerate(chunk_summaries)
    )
    final = await _call_llm(REDUCE_SYSTEM_PROMPT, _build_titled(title, joined))
    return final, settings.openai_model


def _build_titled(title: str | None, body: str) -> str:
    return f"Title: {title}\n\nContent:\n{body}" if title else f"Content:\n{body}"


async def _call_llm(system_prompt: str, user_content: str) -> str:
    response = await _get_client().chat.completions.create(
        model=settings.openai_model,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_content},
        ],
        temperature=0.3,
    )
    return (response.choices[0].message.content or "").strip()
