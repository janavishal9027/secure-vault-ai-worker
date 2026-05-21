import logging

from fastapi import FastAPI

from app.routers import summarize

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s - %(message)s")

app = FastAPI(title="Digital Notes AI Worker", version="0.1.0")

app.include_router(summarize.router, tags=["summarize"])


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}
