from pydantic import BaseModel, Field


class SummarizeRequest(BaseModel):
    note_id: str = Field(..., alias="noteId")
    title: str | None = None
    content: str = Field(..., min_length=1)

    model_config = {"populate_by_name": True}


class SummarizeResponse(BaseModel):
    note_id: str = Field(..., alias="noteId")
    summary: str
    model: str

    model_config = {"populate_by_name": True}
