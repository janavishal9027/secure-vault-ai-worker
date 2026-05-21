# Multi-stage build for the ai-worker service.
#
# Stage 1: python:3.12-slim — installs deps into a virtualenv so the runtime
#          image doesn't carry build tooling.
# Stage 2: python:3.12-slim — copies the venv + source and runs uvicorn.
#
# Service listens on $APP_PORT (default 8000). The only public endpoint is
# /summarize; /health is used by the readiness probe. The ingress strips the
# /ai-worker prefix via a Traefik StripPrefix middleware.
FROM python:3.12-slim AS build
WORKDIR /app

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
RUN pip install -r requirements.txt

FROM python:3.12-slim
WORKDIR /app

ARG GIT_COMMIT=unknown
ARG BUILD_NUMBER=unknown
ARG BUILD_DATE=unknown
LABEL org.opencontainers.image.revision="${GIT_COMMIT}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.source="https://bitbucket.org/<workspace>/secure-vault-ai-worker"
LABEL bitbucket.build.number="${BUILD_NUMBER}"
LABEL version="${BUILD_NUMBER}"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    APP_HOST=0.0.0.0 \
    APP_PORT=8000

COPY --from=build /opt/venv /opt/venv
COPY app ./app

EXPOSE 8000
ENTRYPOINT ["sh", "-c", "exec uvicorn app.main:app --host ${APP_HOST} --port ${APP_PORT}"]
