# Deployment steps — Render backend + Vercel frontend

Backend: Docker image built from the repo-root `Dockerfile`, serving
`rafnet.api.main:app` with Uvicorn on `0.0.0.0:$PORT` (default `10000`).
Frontend: Vite app in `frontend/`, deployed with **Root Directory = `frontend`**.
No secrets are stored in this repo; every key is entered in a dashboard.

## 1. Create the Render web service

1. Render Dashboard → **New → Web Service** → connect the Git repository, or
   **Blueprint → Use Existing Blueprint** and select `render.yaml` at the repo
   root (it declares one Docker web service and `healthCheckPath: /healthz`).
2. Use the **repo root** as the Docker build context; `Dockerfile` at the root.
   The Blueprint already sets `dockerfilePath: ./Dockerfile`.
3. Instance size: the full image needs **at least 1 GB RAM; 2 GB+ recommended**.
   Do not deploy the 512 MB Starter tier — torch + WavLM will OOM.
4. Set **Health Check Path** to `/healthz` (anonymous load-balancer probe).
5. Fill in the four dashboard-only variables in section 2 before deploying.
6. Watch deploy logs for `RAFNet API started (legacy=on)` and no
   `Unsafe production configuration` error. `GET /healthz` must return
   `{"status":"ok"}` (not `degraded`).
7. Render injects `PORT` automatically; do not override it. Render disks are
   ephemeral — anything downloaded at runtime is lost on restart, which is why
   WavLM is baked into the image.

## 2. Secrets to set in the Render dashboard

These are `sync: false` in `render.yaml`, so no values live in git:

| Variable | What to enter |
| --- | --- |
| `SUPABASE_URL` | Project URL from Supabase. |
| `SUPABASE_ANON_KEY` | Publishable/anon key — used to validate Supabase access tokens. |
| `SUPABASE_SERVICE_ROLE_KEY` | Server-side key for analysis persistence (never exposed to the browser). |
| `SOC_CORS_ORIGINS` | Exact Vercel frontend origin, e.g. `https://<frontend-host>`; no trailing slash, never `*`. Add more origins comma-separated if needed. |

Defaults already set in the Dockerfile/Blueprint (not secrets): `RAFNET_ENV=production`,
`SOC_REQUIRE_AUTH=true`, `MOCK_INFERENCE=false`, `RAFNET_DEVICE=cpu`, `HF_HOME=/opt/hf-cache`.

## 3. Vercel settings

1. Import the same Git repo; set **Root Directory = `frontend`**.
2. Framework preset: **Vite**. Build command: `npm run build`
   (`tsc && vite build`). Output directory: `dist`. Install command: `npm install`.
3. Environment variables (Vite exposes only `VITE_*`, at **build** time):
   - `VITE_API_URL` = `https://<render-backend-host>` (no trailing slash).
   - `VITE_WS_URL` = `wss://<render-backend-host>/ws/live` — optional; when empty,
     it is derived from `VITE_API_URL` (`https` → `wss`, `http` → `ws`).
   - `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` — email auth. Leave empty for
     the labeled DEV MODE login. **Never** put a service-role key here.
4. SPA routing: add a rewrite of all paths to `/index.html` (e.g. a
   `frontend/vercel.json` with `{"rewrites":[{"source":"/(.*)","destination":"/index.html"}]}`),
   so React Router deep links survive refresh.
5. Redeploy after changing any `VITE_*` value — they are compiled into the bundle.
6. Source of truth: `frontend/.env.example`, `frontend/src/services/api.ts`
   (`API_BASE_URL`, `WS_URL`), `frontend/src/lib/useLiveSocket.ts` (uses `WS_URL`
   and appends `?token=` for browser WS auth).

## 4. Fail-closed production startup + exact backend env vars

`rafnet.api.main` calls `validate_security_config()` in its lifespan before
loading models (`src/rafnet/api/main.py:88`, `src/rafnet/soc/auth.py:47`). In
production it raises `RuntimeError` and refuses to boot if:

- `SOC_REQUIRE_AUTH` is false,
- `SUPABASE_URL` plus an anon or service key is missing,
- `SOC_CORS_ORIGINS` is empty or contains `*`.

At request time, missing/invalid tokens get 401 and a Supabase outage gets 503
(fail closed, no anonymous fallback).

Required to boot in production:

| Variable | Source |
| --- | --- |
| `RAFNET_ENV=production` | Dockerfile / Blueprint |
| `SOC_REQUIRE_AUTH=true` | Dockerfile / Blueprint |
| `SUPABASE_URL` | dashboard (`sync: false`) |
| `SUPABASE_ANON_KEY` **or** `SUPABASE_SERVICE_ROLE_KEY` | dashboard (`sync: false`) |
| `SOC_CORS_ORIGINS` (explicit, non-wildcard) | dashboard (`sync: false`) |

Required for full functionality: `SUPABASE_SERVICE_ROLE_KEY` (without it the
store silently falls back to in-memory, so history is lost on restart),
`MOCK_INFERENCE=false`, `RAFNET_DEVICE=cpu`, `PORT` (Render injects it),
`HF_HOME` and `MODEL_CHECKPOINT_DIR` (both default correctly in the image).

Optional tunables with safe defaults: `RISK_*`, `RATE_LIMIT_*`,
`MAX_REQUEST_BYTES`, `TRUST_PROXY`, `LATENCY_*`, `ANTISPOOF_ENABLE`,
`ORIGIN_MODEL_DISABLE`, `ORIGIN_CHECKPOINT_PATH`, `SCAM_TEXT_MODEL_PATH`,
`DECISION_THRESHOLDS_PATH`, `EXPERIMENTS_DIR`, `REPORTS_DIR`, `RAFNET_ENABLE_ADMIN`.

## 5. Runtime files that are gitignored or absent (and what degrades)

| File / artifact | Status | Impact when missing |
| --- | --- | --- |
| `experiments/checkpoints/{classical_logistic.pkl,quantum_branch.pkl,gateway2.pth,calibrator.pkl,decision_gate.pkl}` | Tracked and copied into the image | Required branches fail to load; `/healthz` returns `degraded` and analysis returns an error (never a silent 0.5 verdict). |
| `configs/decision_thresholds.json`, `configs/origin_config.json` | Tracked and copied | Missing thresholds fall back to shipped defaults; origin UNCERTAIN band stays a labeled placeholder. |
| `models/stacking.json` | Tracked despite `models/` being gitignored; copied | Ensemble abstains → `REVIEW`, CRITICAL disabled; main RAFNet verdict still works. |
| `models/head_phase4.pt` (~3.0 MB) | Gitignored (`models/`, `*.pt`); present locally, absent from clones | WavLM head unavailable → 4-feature v2 stack fields omitted; analysis falls back to the 3-feature stack. Non-fatal. |
| `models/stack_phase4.json` | Gitignored (`models/`); present locally | Same v2 fallback as above. |
| `models/origin_classifier.pt` | Gitignored; **not present locally either** | `origin: null` and the UI shows "Origin model not installed". No fabricated origin scores. |
| `models/scam_text.joblib` (~154 KB) | Gitignored (`*.joblib`) | Call-risk text classifier unavailable → rules-only mode (`/api/capabilities` reports it). |
| `microsoft/wavlm-base-plus` HF weights | Baked into `/opt/hf-cache` at build time (~94M params, ~360 MB fp32, ~400 MB cache) | If the bake is skipped or the cache is lost, **first boot downloads from HF Hub** (egress + ~0.4 GB ephemeral disk). Without it the real model/head/origin loads fail or degrade. |
| `mo-thecreator/...` + `Bisher/...` HF anti-spoof models | Not baked; fetched lazily on first analysis | With no egress, `p_mo`/`p_bisher` are null → ensemble abstains → `REVIEW`. Main verdict still works. To disable cleanly set `ANTISPOOF_ENABLE=false`. |
| `reports/*.json` | Not copied into the image | `/api/evaluation` and `/api/origin-evaluation` report `evaluated: false`. Non-fatal. |
| `data/`, `samples/` | Gitignored | Not needed for inference. |

Do not add the large artifacts to git. Supply real checkpoints at runtime via
`ORIGIN_CHECKPOINT_PATH` / `SCAM_TEXT_MODEL_PATH`, or add explicit `COPY` lines
to the Dockerfile from a private artifact source if you need them in the image.

Resource budget for first boot: **≥1 GB RAM (2 GB+ recommended)** — WavLM alone
is ~360 MB fp32 and torch + app push peak RSS past the 512 MB tier, roughly
0.8–1.2 GB. Disk: budget ~2–3 GB for the built image; if the HF cache is not
baked, allow egress plus ~0.4 GB for WavLM on first boot and up to ~0.3–0.8 GB
more when the two anti-spoof models are first requested.

## 6. Smoke test

1. `GET /healthz`: `curl -sS https://<render-backend-host>/healthz` →
   `{"status":"ok"}`. `degraded` means the real model did not load.
2. Login from the Vercel frontend with a Supabase email account; confirm the UI
   is authenticated and that requests carry an `Authorization: Bearer ...` header.
3. `GET /api/health` with that token → `model_loaded: true`, `mock_mode: false`.
4. One analysis: upload a short WAV on the Analyze page (or
   `curl -F file=@sample.wav -H "Authorization: Bearer <token>" https://<render-backend-host>/api/analyze`)
   → HTTP 200 with `prediction`, `prob_synthetic`, `mock: false`, `risk_score`,
   `model_version`. Confirm it appears in History for that user only.
5. Negative checks: anonymous `/api/analyze` → 401; WebSocket
   `wss://<render-backend-host>/ws/live?token=<token>` reaches `LIVE`; an
   `OPTIONS` preflight from the Vercel origin is allowed.
