def split_into_chunks(text: str, max_chars: int) -> list[str]:
    if not text:
        return []

    paragraphs = [p for p in text.split("\n\n") if p.strip()]
    chunks: list[str] = []
    buffer: list[str] = []
    buffer_len = 0

    def flush() -> None:
        nonlocal buffer, buffer_len
        if buffer:
            chunks.append("\n\n".join(buffer))
            buffer = []
            buffer_len = 0

    for paragraph in paragraphs:
        p_len = len(paragraph)

        if p_len > max_chars:
            flush()
            for start in range(0, p_len, max_chars):
                chunks.append(paragraph[start : start + max_chars])
            continue

        if buffer_len + p_len + 2 > max_chars and buffer:
            flush()

        buffer.append(paragraph)
        buffer_len += p_len + 2

    flush()
    return chunks
