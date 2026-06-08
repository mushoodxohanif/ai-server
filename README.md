# AI Server

On-premises AI gateway running on a **MacBook Pro (Apple M5 Pro, 48 GB RAM)**. [Ollama](https://ollama.com) serves local LLMs; [LiteLLM](https://docs.litellm.ai/) sits in front as an OpenAI-compatible proxy with authentication, rate limits, spend tracking, and a web admin UI. **LAN HTTPS** is provided by [Caddy](https://caddyserver.com/) at `https://<mac-lan-ip>` — no hostname or DNS setup required.

---

## Architecture

```
┌─────────────────┐     HTTPS (LAN)          ┌──────────────────────────────┐
│  Employees      │ ───────────────────────► │  https://<mac-lan-ip>        │
│  (Cursor, CLI,  │      e.g. :443           │  Caddy :443 → LiteLLM :4000  │
│   web apps)     │                          └──────────────┬───────────────┘
└─────────────────┘                                         │
                                                            ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  MacBook Pro M5 Pro                                                          │
│                                                                              │
│  ┌───────────────┐    ┌─────────────────────┐    ┌────────────────────────┐  │
│  │ Caddy         │───►│ LiteLLM             │───►│ Ollama :11434          │  │
│  │ :443 (Docker) │    │ :4000               │    │                        │  │
│  └───────────────┘    │ • Auth/keys         │    │ • phi4:14b             │  │
│                       │ • Rate limits       │    │ • qwen3:32b            │  │
│                       │ • Admin UI          │    │ • (more planned)       │  │
│                       │ • Virtual API keys  │    └────────────────────────┘  │
│                       └──────────┬──────────┘                                │
│                                  │                                           │
│                       ┌──────────▼──────────┐                                │
│                       │ PostgreSQL (Docker) │                                │
│                       │ :5432               │                                │
│                       │ • Users & API keys  │                                │
│                       └─────────────────────┘                                │
└──────────────────────────────────────────────────────────────────────────────┘
```

**Request flow:** Client → LiteLLM (`Authorization: Bearer <key>`) → Ollama → response streamed back through LiteLLM.

---

## Repository contents

| File | Purpose |
|------|---------|
| `litellm_config.yaml` | Model routing, fallbacks, rate limits, database settings |
| `docker-compose.yml` | PostgreSQL + Caddy reverse proxy (LAN HTTPS) |
| `Caddyfile` | TLS and reverse proxy on `:443` → LiteLLM (any LAN IP) |
| `.env` | Secrets and LAN URL (`LAN_IP`, `PROXY_BASE_URL`, …) |
| `scripts/show-lan-url.sh` | Print this Mac's LAN IP and employee URLs |
| `scripts/sync-lan-env.sh` | Update `LAN_IP` and `PROXY_BASE_URL` in `.env` |
| `scripts/start-litellm.sh` | Start LiteLLM with `.env` loaded |
| `scripts/trust-caddy-ca.sh` | Install Caddy internal CA on macOS (one-time per device) |
| `venv/` | Python 3.13 virtualenv with LiteLLM 1.88.0 |

---

## Configured models

LiteLLM exposes these **use-case proxy names** (OpenAI-compatible). Each maps to one Ollama model on `localhost:11434`.

| Proxy name | Ollama model | Use case |
|------------|--------------|----------|
| `research` | `deepseek-r1:70b` | Research — synthesizing web search results |
| `coding` | `qwen2.5-coder:32b` | Code generation and debugging |
| `chat` | `phi4:14b` | Fast conversational dialogue |
| `general` | `qwen3:32b` | All-rounder — tools, thinking, general tasks |
| `image` | `x/flux2-klein` | Text-to-image generation |
| `video` | *(placeholder)* | Returns "coming soon" — no Ollama video model yet |

**Fallback:** If `research`, `coding`, or `chat` fails, LiteLLM retries with `general`.

### Currently installed in Ollama

```bash
ollama list
```

Installed today: `phi4:14b`, `qwen3:32b`. Remaining pulls in progress:

```bash
ollama pull deepseek-r1:70b      # research (~40 GB)
ollama pull qwen2.5-coder:32b    # coding (~20 GB)
ollama pull x/flux2-klein        # image (~6 GB)
```

On 48 GB RAM, Ollama loads one large model at a time — expect swap latency when switching between `research` (~40 GB) and `general` (~20 GB).

### Image and video generation

- **Image:** `image` proxy is registered; Open WebUI image pipeline wiring is planned in a later phase. LiteLLM chat API does not natively route Ollama image models — use Open WebUI Image mode or a pass-through endpoint.
- **Video:** `video` proxy returns a static placeholder response until Ollama or a worker Mac supports video generation.

---

## Authentication and access

Access is **master key + virtual API keys** for admin and employees on the LAN.

### Admin UI login

| Field | Value |
|-------|-------|
| URL (LAN) | `https://<LAN_IP>/ui/login/` — run `./scripts/show-lan-url.sh` |
| URL (local) | http://localhost:4000/ui/login/ |
| Username | `admin` |
| Password | Master key (see `.env` / `LITELLM_MASTER_KEY`) |

### Employee API keys

Create **virtual keys** in the admin UI (Virtual Keys) and share them with employees on the LAN. Each key can have its own budget, rate limits, and model access.

Programmatic access uses `Authorization: Bearer <key>` against the OpenAI-compatible endpoints.

**Master key** — full admin access only; do not share with employees.

---

## LiteLLM settings (summary)

From `litellm_config.yaml`:

| Setting | Value |
|---------|-------|
| Listen port | `4000` (when started with `--port 4000`) |
| Max parallel requests | 10 |
| Request timeout | 600 s |
| Retries | 2 |
| Routing strategy | `usage-based-routing` |
| Router timeout | 300 s |
| `store_model_in_db` | `true` |

Database: `postgresql://litellm:litellm@localhost:5432/litellm` (Docker).

---

## Prerequisites

- macOS on Apple Silicon (M5 Pro)
- [Ollama](https://ollama.com/download) installed and running
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (for PostgreSQL)
- Python 3.13

---

## Initial setup

### 1. Python environment

```bash
cd /Users/mushoodhanif/Documents/code/ai-server
python3 -m venv venv
source venv/bin/activate
pip install 'litellm[proxy]'
```

If Prisma client generation is needed after install:

```bash
export DATABASE_URL="postgresql://litellm:litellm@localhost:5432/litellm"
cd venv/lib/python3.13/site-packages/litellm/proxy
prisma generate
```

### 2. Environment variables

Create `.env` in the project root:

```bash
LITELLM_MASTER_KEY="sk-master-<generate-a-long-random-string>"
DATABASE_URL="postgresql://litellm:litellm@localhost:5432/litellm"

# This Mac's LAN IP — employees use https://<LAN_IP>/ui/
LAN_IP="172.16.10.215"
PROXY_BASE_URL="https://172.16.10.215"
```

Generate a strong master key:

```bash
openssl rand -hex 32 | sed 's/^/sk-master-/'
```

> **Security:** Prefer keeping secrets in `.env` only. The master key is also duplicated in `litellm_config.yaml` today — consider removing it from the YAML and relying on `LITELLM_MASTER_KEY` from the environment.

### 3. PostgreSQL and Caddy

```bash
docker compose up -d
```

This starts **PostgreSQL** and **Caddy** (LAN HTTPS on ports 80/443).

Verify:

```bash
docker compose ps
# litellm-postgres   Up   0.0.0.0:5432->5432/tcp
# ai-caddy           Up   0.0.0.0:443->443/tcp, 0.0.0.0:80->80/tcp
```

### 4. LAN URL

Find the URL employees should use (no DNS or hostname required):

```bash
./scripts/show-lan-url.sh
# Example output: https://172.16.10.215/ui

./scripts/sync-lan-env.sh   # write detected IP into .env
```

Set `LAN_IP` manually in `.env` if auto-detection picks the wrong interface.

Trust Caddy's internal TLS certificate once per Mac (avoids browser warnings):

```bash
./scripts/trust-caddy-ca.sh
```

### 5. Ollama models

```bash
ollama pull qwen3:32b
ollama pull phi4:14b
# Pull additional models as needed (see table above)
```

---

## Running the server

Start services in order:

```bash
# Terminal 1 — database (if not already running)
docker compose up -d

# Terminal 2 — LiteLLM proxy
./scripts/start-litellm.sh
```

Ollama runs as a macOS service by default. Confirm it is up:

```bash
curl http://localhost:11434/api/tags
```

### Health checks

```bash
# Liveness (no auth) — local
curl http://localhost:4000/health/liveliness

# Liveness via Caddy (replace with your LAN IP)
curl -sk https://172.16.10.215/health/liveliness

# UI config
curl -sk https://172.16.10.215/litellm/.well-known/litellm-ui-config

# Readiness (requires auth)
curl http://localhost:4000/health/readiness \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"

# List models
curl http://localhost:4000/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

---

## Using the API

Base URL (LAN): `https://<LAN_IP>` — run `./scripts/show-lan-url.sh`  
Base URL (local): `http://localhost:4000`

LiteLLM implements the [OpenAI Chat Completions API](https://platform.openai.com/docs/api-reference/chat).

### cURL example

```bash
curl http://localhost:4000/chat/completions \
  -H "Authorization: Bearer <your-api-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "phi4",
    "messages": [{"role": "user", "content": "Explain what a binary search is."}],
    "stream": false
  }'
```

### Cursor / IDE configuration

| Setting | Value |
|---------|-------|
| Base URL | `https://<LAN_IP>` (LAN) or `http://localhost:4000` (local) |
| API key | Virtual key from admin UI |
| Model | Any proxy name (e.g. `qwen3-32b`, `qwen2.5-coder-32b`) |

### Streaming

All models in `litellm_config.yaml` have `stream: true`. Send `"stream": true` in the request body for token-by-token responses.

---

## LAN HTTPS

The server is exposed on the LAN at **`https://<LAN_IP>`** via Caddy in Docker (port **443**). Ollama runs separately on port **11434** — that is not the web UI.

| Component | Role |
|-----------|------|
| `Caddyfile` | Internal CA TLS on `:443` + reverse proxy to LiteLLM |
| `LAN_IP` / `PROXY_BASE_URL` | Your Mac's LAN address in `.env` |
| `./scripts/show-lan-url.sh` | Print the exact URL for employees |

Verify after startup (use your LAN IP):

```bash
curl -sk https://172.16.10.215/health/liveliness
```

**Ports:**

| Service | Port | URL |
|---------|------|-----|
| LiteLLM UI / API (HTTPS) | 443 | `https://<LAN_IP>/ui/login/` |
| LiteLLM (direct, HTTP) | 4000 | `http://localhost:4000` |
| Ollama | 11434 | `http://localhost:11434` (internal only) |

---

## Admin UI

| Page | URL |
|------|-----|
| Dashboard | `https://<LAN_IP>/ui/login/` |
| Dashboard (local) | http://localhost:4000/ui |
| Swagger API docs | `https://<LAN_IP>/` |

From the UI you can:

- Create and revoke virtual keys for teams/users
- View usage and spend
- Manage model access per key

---

## Operational notes

### Keep the Mac awake

LiteLLM and Ollama need the MacBook running and awake. Consider:

- System Settings → Displays → Prevent automatic sleeping when display is off (on power adapter)
- A `launchd` plist or `pmset` configuration for server-like behavior

### Resource usage

Large models (70B class) will consume most of the 48 GB unified memory. Only one large model typically runs at a time in Ollama; smaller models like `phi4` load faster for quick tasks.

### PostgreSQL persistence

Data lives in the Docker volume `litellm_pgdata`. Back it up before major changes:

```bash
docker exec litellm-postgres pg_dump -U litellm litellm > litellm_backup.sql
```

### Startup warning (harmless)

You may see:

```
Could not import litellm.integrations.weave
```

This is an optional Weights & Biases integration missing OpenTelemetry. It does not affect proxy operation. Ignore it, or install `pip install opentelemetry-api opentelemetry-sdk` to silence it.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Not connected to DB!` on UI login | PostgreSQL not running | `docker compose up -d` |
| Prisma / migration errors | DB URL wrong or Prisma client stale | Check `DATABASE_URL`; run `prisma generate` in LiteLLM proxy dir |
| `the URL must start with postgresql://` | SQLite was used | LiteLLM requires PostgreSQL, not SQLite |
| Model not found | Ollama image not pulled | `ollama pull <model>` |
| Login redirects to `localhost:4000` | Missing trailing slash or stale browser cache | Use `https://<LAN_IP>/ui/login/`; clear `litellm_worker_url` in localStorage |
| 502 from Caddy | LiteLLM not running | `./scripts/start-litellm.sh` |
| `ERR_SSL_PROTOCOL_ERROR` on IP URL | Browser sends no SNI for IP addresses | `default_sni` in Caddyfile; run `./scripts/trust-caddy-ca.sh` |
| TLS warning in browser | Caddy internal CA not trusted | Run `./scripts/trust-caddy-ca.sh` on that device |
| Wrong IP after network change | `LAN_IP` stale | Re-run `./scripts/sync-lan-env.sh` |

---

## Security checklist

- [ ] Rotate master key if it was ever committed or shared
- [ ] Move `master_key` out of `litellm_config.yaml` into `.env` only
- [ ] Add `.env` to `.gitignore` before pushing to git
- [ ] Run `./scripts/show-lan-url.sh` and share the URL with employees on the LAN
- [ ] Trust Caddy CA on employee Macs (`./scripts/trust-caddy-ca.sh`)
- [ ] Create per-employee virtual keys in the admin UI — do not share the master key
- [ ] Set `max_budget` per key/team in the admin UI if needed

---

## Version reference

| Component | Version |
|-----------|---------|
| LiteLLM | 1.88.0 |
| litellm-enterprise | 0.1.42 |
| Python | 3.13.0 |
| PostgreSQL | 16 (Alpine, Docker) |
| Caddy | 2 (Alpine, Docker) |
| macOS | 26.5.1 |
| Hardware | MacBook Pro, Apple M5 Pro, 48 GB RAM |

---

## Quick reference

```bash
# Start everything
docker compose up -d
./scripts/start-litellm.sh

# Stop LiteLLM
# Ctrl+C in the LiteLLM terminal

# Stop Docker services (PostgreSQL + Caddy)
docker compose down

# Pull a new Ollama model
ollama pull <model>:<tag>

# Add a model to LiteLLM
# Edit litellm_config.yaml model_list, then restart LiteLLM
```
