import logging

from fastapi import APIRouter, HTTPException, status

from app.llm import summarize_text
from app.schemas import SummarizeRequest, SummarizeResponse

router = APIRouter()
log = logging.getLogger(__name__)


@router.post("/summarize", response_model=SummarizeResponse)
async def summarize(request: SummarizeRequest) -> SummarizeResponse:
    try:
        summary, model = await summarize_text(request.title, request.content)
    except Exception as exc:
        log.exception("summarization failed for note %s", request.note_id)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"summarization failed: {exc}",
        ) from exc

    return SummarizeResponse(noteId=request.note_id, summary=summary, model=model)
