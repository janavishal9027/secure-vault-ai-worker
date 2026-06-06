# `ai-worker`

The `ai-worker` is a small stateless HTTP microservice in the **Digital Notes / secure-vault** platform that produces AI summaries of notes. Despite the "worker" name, it is **not** a queue consumer — it is a [FastAPI](https://fastapi.tiangolo.com/) service that exposes a single `POST /summarize` endpoint. The notes service calls it synchronously (its `SummaryRequestConsumer` POSTs note content here), and the worker calls an OpenAI-compatible chat-completions API (OpenRouter by default) to generate a concise 2–4 sentence summary. Long notes are split into character-bounded chunks, summarized in parallel, then reduced into a single cohesive summary (map-reduce). It keeps no database or persistent state of its own.

## Tech stack

| Concern | Choice |
| --- | --- |
| Language | Python 3.12 |
| Web framework | FastAPI 0.118 |
| ASGI server | Uvicorn 0.34 (`uvicorn[standard]`) |
| Config | pydantic-settings 2.7 (env / `.env`) |
| Validation | Pydantic 2.10 |
| LLM client | `openai` 1.59 (`AsyncOpenAI`, OpenAI-compatible — defaults to OpenRouter) |
| Container | Multi-stage `python:3.12-slim` |
| Orchestration | Kubernetes (k3s in LXD), Traefik ingress, host nginx |

## How it fits in the platform

The worker sits behind the cluster ingress and is invoked synchronously by the notes service. It has no queue, no database, and no other downstream service except the external LLM API.

```
                    host nginx (/ai-worker/*)
                            |
                            v
                Traefik ingress (StripPrefix /ai-worker)
                            |
   notes-service ---------> | ----> ai-worker (FastAPI :8000)
   (SummaryRequestConsumer  |        POST /summarize
    POSTs to /summarize)    |        GET  /health
                                          |
                                          v
                          OpenAI-compatible Chat Completions API
                            (OpenRouter by default — OPENAI_BASE_URL)
```

- **Upstream caller:** the notes service reaches it cluster-internally at `http://${APP_NAME}-service:8000` (its `AI_WORKER_BASE_URL`); external traffic enters via `/ai-worker/*`, with Traefik stripping the prefix so the app sees `/summarize` at root.
- **Downstream dependency:** an OpenAI-compatible chat-completions endpoint (`OPENAI_BASE_URL`, default `https://openrouter.ai/api/v1`).
- **No queue / DB:** unlike the sibling `ai-core-service`, this service does not consume from a message broker or persist embeddings.

> **Note on config drift:** the runtime code (see [app/config.py](app/config.py) and [app/llm.py](app/llm.py)) reads `OPENAI_*` variables. The deploy scripts and k8s manifests ([ci/deploy.sh](ci/deploy.sh), [deployment.yml](deployment.yml)) instead inject `GEMINI_API_KEY` / `GEMINI_MODEL`. Because the settings model uses `extra="ignore"`, those `GEMINI_*` vars are currently **not consumed** by the application — to talk to a real LLM you must supply `OPENAI_API_KEY` (and optionally `OPENAI_BASE_URL` / `OPENAI_MODEL`).

## Running locally

### Prerequisites

- Python 3.12+
- An API key for an OpenAI-compatible chat-completions provider (OpenRouter or OpenAI)

### Environment variables

Configuration is loaded by pydantic-settings from the process environment or a `.env` file in the working directory (see [app/config.py](app/config.py)). Variable names are matched case-insensitively to the settings fields below.

| Variable | Default | Description |
| --- | --- | --- |
| `OPENAI_API_KEY` | `""` (required at call time) | API key for the chat-completions provider. If unset, `/summarize` raises a `RuntimeError`. |
| `OPENAI_BASE_URL` | `https://openrouter.ai/api/v1` | Base URL of the OpenAI-compatible API. OpenRouter-specific headers are added automatically when the URL contains `openrouter.ai`. |
| `OPENAI_MODEL` | `openai/gpt-oss-120b` | Model name passed to the chat-completions call. |
| `OPENAI_APP_TITLE` | `secure-vault` | Sent as the `X-Title` header to OpenRouter. |
| `APP_HOST` | `0.0.0.0` | Host the ASGI server binds to. |
| `APP_PORT` | `8000` | Port the ASGI server binds to. |
| `SUMMARY_CHUNK_THRESHOLD_CHARS` | `3500` | Content longer than this is split into chunks (map-reduce); shorter content is summarized in one call. |
| `SUMMARY_CHUNK_SIZE_CHARS` | `3500` | Max characters per chunk when splitting. |
| `SUMMARY_MAX_CONCURRENT_CHUNKS` | `5` | Max chunk summaries computed in parallel (asyncio semaphore). |

The committed [.env](.env) is a template with `${...}` placeholders (`OPENAI_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_MODEL`, `APP_HOST`, `APP_PORT`) meant to be substituted from the real environment.

> CI/deploy also accepts `GEMINI_API_KEY` (required), `GEMINI_MODEL` (default `gemini-2.5-flash`), `REPLICAS`, and the three `SUMMARY_*` knobs above — see [ci/deploy.sh](ci/deploy.sh). As noted above, the `GEMINI_*` values are injected into the pod but not read by the current code.

### Start command

```bash
# from the ai-worker/ directory
python -m venv .venv
.venv/Scripts/activate        # Windows; use: source .venv/bin/activate on Linux/macOS
pip install -r requirements.txt

# run the API (matches the Dockerfile entrypoint)
uvicorn app.main:app --host 0.0.0.0 --port 8000

# or, during development, with auto-reload:
uvicorn app.main:app --reload
```

## What it does (HTTP endpoints)

The service exposes two endpoints (see [app/main.py](app/main.py) and [app/routers/summarize.py](app/routers/summarize.py)):

| Method | Path | Description |
| --- | --- | --- |
| `POST` | `/summarize` | Summarize a note. Returns the summary and the model used. |
| `GET` | `/health` | Liveness/readiness probe — returns `{"status": "ok"}`. |

### `POST /summarize`

Request body (see [app/schemas.py](app/schemas.py)) — fields accept both snake_case and the camelCase aliases:

```json
{
  "noteId": "abc-123",
  "title": "Optional title",
  "content": "The note body to summarize (min length 1)."
}
```

Response:

```json
{
  "noteId": "abc-123",
  "summary": "A faithful 2-4 sentence summary...",
  "model": "openai/gpt-oss-120b"
}
```

On any failure of the upstream LLM call the endpoint returns **HTTP 502** with a `summarization failed: ...` detail.

### Processing flow

Summarization logic lives in [app/llm.py](app/llm.py) and [app/chunking.py](app/chunking.py):

1. **Short notes** (`len(content) <= SUMMARY_CHUNK_THRESHOLD_CHARS`): a single chat-completions call with a "concise note-summarization" system prompt, temperature `0.3`.
2. **Long notes** (map-reduce):
   - `split_into_chunks` splits content on paragraph boundaries into `SUMMARY_CHUNK_SIZE_CHARS`-sized chunks (oversized paragraphs are hard-split).
   - Each chunk is summarized concurrently, bounded by an asyncio semaphore of `SUMMARY_MAX_CONCURRENT_CHUNKS`.
   - The numbered partial summaries are combined by a final "reduce" call into one 3–5 sentence summary.
3. The LLM client (`AsyncOpenAI`) is lazily constructed with a 60s per-call timeout and adds OpenRouter `HTTP-Referer` / `X-Title` headers when the base URL targets `openrouter.ai`.

## Build, test & package

There is no test suite or build/packaging manifest beyond [requirements.txt](requirements.txt) in this service. Local setup:

```bash
pip install -r requirements.txt          # install dependencies
python -c "import app.main"               # quick smoke import
uvicorn app.main:app --reload             # run locally
```

The deployment artifact is the Docker image (below); there is no wheel/sdist packaging step.

## Docker

The [Dockerfile](Dockerfile) is a two-stage `python:3.12-slim` build: stage 1 installs dependencies into a `/opt/venv` virtualenv, stage 2 copies the venv plus the `app/` source and runs Uvicorn.

```bash
# build
docker build -t ai-worker:local .

# run (provide a real key for live summaries)
docker run --rm -p 8000:8000 \
  -e OPENAI_API_KEY=sk-... \
  ai-worker:local
```

- Exposes port `8000`; entrypoint runs `uvicorn app.main:app --host ${APP_HOST} --port ${APP_PORT}`.
- Build args `GIT_COMMIT`, `BUILD_NUMBER`, `BUILD_DATE` populate OCI image labels.

## Deployment

Deployment targets a `secure-vault-*` k3s cluster running inside an LXD container, fronted by Traefik and host nginx. Two scripts drive it:

- [ci/deploy.sh](ci/deploy.sh) — runs in CI. Renders [deployment.yml](deployment.yml), [service.yml](service.yml), [ingress.yml](ingress.yml), and the nginx snippet by substituting `${...}` placeholders, then `scp`s them to the LXD host and invokes the remote script over SSH. Requires `VPS_USER`, `VPS_HOST`, `REMOTE_DIR`, `LXD_CONTAINER`, `KUBE_NAMESPACE`, `APP_NAME`, `IMAGE_REPO`, `IMAGE_TAG`, `INGRESS_HOST`, `LXD_BRIDGE_IP`, `GEMINI_API_KEY`.
- [ci/deploy-remote.sh](ci/deploy-remote.sh) — runs on the LXD host. Waits for k3s, ensures the namespace, applies the manifests, waits for the deployment to become `Available`, runs a `GET /ai-worker/health` routing test through Traefik, then installs the nginx location snippet and reloads nginx.

Kubernetes resources (names derived from `${APP_NAME}`, e.g. `ai-worker`):

| Manifest | Resource | Notes |
| --- | --- | --- |
| [deployment.yml](deployment.yml) | `${APP_NAME}-deployment` | `containerPort: 8000`, `/health` readiness + liveness probes, CPU `100m`–`750m`, mem `256Mi`–`512Mi`. |
| [service.yml](service.yml) | `${APP_NAME}-service` | `ClusterIP` on port `8000` — what the notes service's `AI_WORKER_BASE_URL` points at. |
| [ingress.yml](ingress.yml) | `${APP_NAME}-ingress` + `${APP_NAME}-stripprefix` Middleware | Routes `/ai-worker` and strips the prefix so the pod sees `/summarize` at root. |
| [ci/nginx/ai-worker.location.conf](ci/nginx/ai-worker.location.conf) | host nginx `location /ai-worker/` | Proxies to `http://${LXD_BRIDGE_IP}:80` with a generous 180s read timeout for long parallel summaries. |

## Project layout

```
ai-worker/
├── app/
│   ├── __init__.py
│   ├── main.py                # FastAPI app: mounts /summarize router + /health
│   ├── config.py              # pydantic-settings Settings (OPENAI_*, SUMMARY_* knobs)
│   ├── llm.py                 # AsyncOpenAI client + map-reduce summarization
│   ├── chunking.py            # paragraph-aware char-bounded text splitter
│   ├── schemas.py             # SummarizeRequest / SummarizeResponse models
│   └── routers/
│       ├── __init__.py
│       └── summarize.py       # POST /summarize handler
├── ci/
│   ├── deploy.sh              # CI-side: render manifests, ship, run remote
│   ├── deploy-remote.sh       # host-side: apply manifests, verify, wire nginx
│   └── nginx/
│       └── ai-worker.location.conf
├── deployment.yml             # k8s Deployment (templated)
├── service.yml                # k8s ClusterIP Service (templated)
├── ingress.yml                # k8s Ingress + Traefik StripPrefix Middleware
├── Dockerfile                 # multi-stage python:3.12-slim, uvicorn entrypoint
├── requirements.txt           # fastapi, uvicorn, pydantic, pydantic-settings, openai
└── .env                       # local env template (placeholder values)
```
