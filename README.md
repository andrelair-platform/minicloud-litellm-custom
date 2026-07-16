# minicloud-litellm-custom — Enterprise AI Gateway

[![CI](https://github.com/andrelair-platform/minicloud-litellm-custom/actions/workflows/ci.yml/badge.svg)](https://github.com/andrelair-platform/minicloud-litellm-custom/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Supply chain: cosign](https://img.shields.io/badge/supply%20chain-cosign%20signed-green)](https://github.com/sigstore/cosign)

Custom LiteLLM image and configuration powering the Minicloud enterprise AI Gateway.
Unified 8 cloud and local LLM providers behind a single OpenAI-compatible endpoint with
enterprise governance: PII/DLP guardrails, department key budgets, circuit breaker, and
full Langfuse LLMOps tracing.

**Live endpoint:** <https://litellm.devandre.sbs/v1/models>  
**Admin UI:** <https://litellm.devandre.sbs/>  
**Portfolio:** <https://www.devandre.sbs>  
**Docs:** <https://andrelair-platform.github.io/minicloud-platform-docs/>

---

## Table of Contents

- [Try It Now](#try-it-now)
- [Architecture](#architecture)
- [Department Key Governance](#department-key-governance-3-tiers)
- [Live Screenshots](#live-screenshots)
- [Repo Contents](#repo-contents)
- [Config is source of truth](#config-is-source-of-truth)
- [Making changes](#making-changes)
- [CI/CD Pipeline](#cicd-pipeline)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Try It Now

```bash
# List available models (public, no auth)
curl https://litellm.devandre.sbs/v1/models

# Chat completions via the enterprise gateway
curl -s -X POST https://litellm.devandre.sbs/v1/chat/completions \
  -H "Authorization: Bearer sk-portfolio-demo" \
  -H "Content-Type: application/json" \
  -d '{"model": "groq-fallback", "messages": [{"role": "user", "content": "What is an LLM gateway?"}], "max_tokens": 60}'
```

> `sk-portfolio-demo` is a public read-only key capped at $0.50/30 days, restricted to `groq-fallback` + `phi4-mini`.
> Every call is traced in Langfuse and increments the Grafana spend counter.

---

## Architecture

```
                        ┌─────────────────────────────────────┐
                        │        litellm.devandre.sbs         │
                        │   (Cloudflare Tunnel → NGINX → k3s) │
                        └──────────────┬──────────────────────┘
                                       │ /v1/chat/completions
                        ┌──────────────▼──────────────────────┐
                        │         LiteLLM Router               │
                        │  ┌─────────────────────────────┐    │
                        │  │   Presidio pre_call_hook    │    │  ← PII/DLP masking
                        │  │   (DATE_TIME + LOCATION     │    │    before any provider
                        │  │    excluded for finance)    │    │    sees the prompt
                        │  └─────────────────────────────┘    │
                        │  ┌─────────────────────────────┐    │
                        │  │   Valkey exact-match cache  │    │  ← 600s TTL
                        │  └─────────────────────────────┘    │
                        │  ┌─────────────────────────────┐    │
                        │  │   Circuit breaker           │    │  ← cooldown=60s
                        │  │   (allowed_fails=3)         │    │    failed→quarantine
                        │  └─────────────────────────────┘    │
                        └──┬───────┬───────┬──────────┬───────┘
                           │       │       │          │
              ┌────────────▼─┐ ┌───▼────┐ ┌▼──────┐ ┌▼────────────┐
              │ Ollama local │ │  Groq  │ │OpenAI │ │  DeepSeek   │
              │ phi4-mini    │ │llama-  │ │gpt-4o │ │  reasoner   │
              │ qwen3.5:4b   │ │3.1-8b  │ │gpt-4o-│ │  (cloud-    │
              │ deepseek-r1  │ │instant │ │mini   │ │   first)    │
              └──────────────┘ └────────┘ └───────┘ └─────────────┘
              + Mistral + Gemini + Anthropic Claude + HuggingFace + NVIDIA NIM
```

**Fallback chain:** `Ollama → Groq → DeepSeek` — automatic, zero application changes  
**Secrets:** all 8 provider API keys from HashiCorp Vault via ESO ExternalSecret — zero secrets in git

### Model aliasing

Callers use stable friendly names (`groq-fallback`, `phi4-mini`, `gpt-4o`). LiteLLM maps these to provider-specific IDs internally — switching a backend requires only a config change, not an API contract change.

### Presidio PII guardrail

`DATE_TIME` and `LOCATION` entities are explicitly excluded from the Presidio analyzer. This is required for financial queries where `2024` and `France` are meaningful data, not PII to scrub.

---

## Department Key Governance (3 tiers)

| Tier | Departments | Budget | Model access |
|---|---|---|---|
| Premium | IT, Data, Actuariat, Transformation | $100/30d | All models incl. GPT-4o, Claude |
| Standard | Cyber, Finance, Audit, Juridique, Réassurance, Commercial, Souscription | $30/30d | Standard cloud + local |
| Basic | Sinistres, Ops, RH, SG | $5/30d | Local Ollama only |

Budget caps enforced at the LiteLLM VirtualKey layer — not the application. Requests that exceed the budget or reference a model outside the allowlist are rejected before reaching any provider.

See [`docs/dept-key-governance.md`](docs/dept-key-governance.md) for the full allowlist.

---

## Live Screenshots

**Grafana — LiteLLM Spend & Usage Dashboard**

![Grafana cost dashboard showing $1.67 spend, 2.52M tokens, 1.38K requests](docs/screenshots/grafana-litellm-cost.png)

PostgreSQL datasource provisioned via ESO + Grafana sidecar ConfigMap. Dashboard JSON stored in git as a ConfigMap labelled `grafana_dashboard: "1"` — injected without any UI interaction. SQL queries directly against `LiteLLM_SpendLogs` and `LiteLLM_VerificationToken`.

→ [Live dashboard](https://grafana.devandre.sbs/d/litellm-cost-dept)

---

**Langfuse — phi3-financial Eval Trace (correctness: 1.00)**

![Langfuse trace eval-T11 showing phi3-financial response with correctness score](docs/screenshots/langfuse-phi3-trace.png)

Trace `eval-T11` from the RAG eval CI gate. Input: *"Explain the difference between a call option and a put option."* Tagged `prompt-eval`, git release pinned. Ragas faithfulness=0.80, hit_rate=0.80.

→ [Live Langfuse](https://langfuse.devandre.sbs)

---

**Langfuse — 25-Trace Eval Pipeline**

![Langfuse tracing list showing all 25 eval traces T1-T25 with metric columns](docs/screenshots/langfuse-eval-traces.png)

All 25 eval traces (T1–T25) from the ArgoCD PostSync CI gate. Financial domain questions with per-trace metric scores: `answer_relevancy`, `faithfulness`, `hit_rate`, `mrr`, `rouge_l`.

→ [Live Langfuse](https://langfuse.devandre.sbs)

---

## Repo Contents

| File | Purpose |
|---|---|
| `Dockerfile` | Patches on top of `ghcr.io/berriai/litellm-database:main-latest` (Prisma permissions, libatomic, google-generativeai) |
| `config/litellm-config.yaml` | **Canonical AI Gateway config** — model routing, guardrails, fallbacks, Presidio PII, Valkey cache, circuit breaker |
| `langfuse_prompt_handler.py` | LiteLLM `CustomLogger` — injects the Langfuse production-labelled prompt into every `phi3-financial` request at runtime (5-min in-process cache, fail-open chain) |

---

## Config is source of truth

All AI Gateway changes — add a model, tweak routing, change Presidio rules, adjust circuit breaker — are made by editing `config/litellm-config.yaml` and pushing to `main`.

```
config/litellm-config.yaml   →  CI sync  →  minicloud-gitops/manifests/ai/00-litellm-configmap.yaml
langfuse_prompt_handler.py   →  CI sync  →  minicloud-gitops/manifests/ai/15-langfuse-prompt-handler-configmap.yaml
```

**Never edit `manifests/ai/00-litellm-configmap.yaml` directly in gitops** — the next CI run overwrites it.

---

## Making changes

```bash
# Config change (model, routing, guardrail, circuit breaker)
# 1. Edit config/litellm-config.yaml
# 2. Push to main → CI syncs to gitops → ArgoCD picks up within ~3 min

# Handler change (prompt injection logic)
# 1. Edit langfuse_prompt_handler.py
# 2. Push to main → same CI flow, no image rebuild needed

# Image change (Dockerfile, new Python dependency)
# 1. Edit Dockerfile
# 2. Push to main → CI builds → pushes to Harbor → cosign-signs → bumps gitops image tag
```

---

## CI/CD Pipeline

Every push to `main` triggers `.github/workflows/ci.yml`:

```
push to main
    │
    ├─ 1. Connect to Tailscale (OAuth — TS_OAUTH_CLIENT_ID / TS_OAUTH_SECRET)
    ├─ 2. Trust minicloud CA on the runner (raw PEM — no base64 decode)
    ├─ 3. Sync config/litellm-config.yaml → minicloud-gitops ConfigMap
    ├─ 4. docker build (if Dockerfile changed) → push to harbor.10.0.0.200.nip.io/library/litellm-custom:<sha>
    ├─ 5. Trivy scan — fails on unfixed CRITICAL CVEs
    ├─ 6. cosign sign (keyless — GitHub OIDC → Sigstore Fulcio)
    └─ 7. GPG-signed commit to minicloud-gitops
              └─ ArgoCD webhook → rolling update in ai namespace
```

**Required secrets:**

All 7 secrets are **org-level on `andrelair-platform`** (visibility: all). New repos inherit them automatically — no per-repo setup needed.

| Secret | Purpose |
|---|---|
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client ID — joins tailnet as `tag:ci` |
| `TS_OAUTH_SECRET` | Tailscale OAuth secret |
| `MINICLOUD_CA_CERT` | Self-signed CA PEM — lets Docker daemon and cosign trust Harbor TLS |
| `HARBOR_USER` | Harbor registry username |
| `HARBOR_PASSWORD` | Harbor registry password |
| `GITOPS_TOKEN` | GitHub PAT (`repo` scope) for committing to `minicloud-gitops` |
| `GPG_PRIVATE_KEY` | Armored GPG private key for signing gitops commits (key ID `FD6D39D681DEFA34`) |

---

## Security

- `phi3-financial` is **local-only** — sensitive financial data must never leave the cluster. Routed exclusively to on-premise Ollama instances.
- Cloud models (GPT-4o, Claude, Gemini, DeepSeek) are gated behind Presidio PII masking at the `pre_call` guardrail stage.
- All 8 provider API keys injected from HashiCorp Vault via External Secrets Operator — never stored in this repo.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `sk-portfolio-demo` returns 429 | Public demo key hit its $0.50/30d budget cap | The cap resets monthly — this is expected; use a department key for real workloads |
| Model returns 404 | Virtual model alias not in `config/litellm-config.yaml` | Check `curl https://litellm.devandre.sbs/v1/models` for the available alias list |
| Presidio strips financial context | `DATE_TIME` or `LOCATION` entities being scrubbed | These two entities are excluded by default — check if `config/litellm-config.yaml` was accidentally changed |
| Circuit breaker quarantines a provider | Provider returned ≥ 3 consecutive errors | Cooldown is 60s — traffic auto-routes to the fallback; the quarantined provider recovers automatically |
| `phi3-financial` routes to a cloud provider | Ollama pod not Running | Check `kubectl get pods -n ai -l app=ollama`; phi3-financial is local-only and will fail if no Ollama pod is available |
| Grafana dashboard shows no spend data | LiteLLM PostgreSQL datasource misconfigured | Verify the datasource URL points to `postgresql-ai.ai.svc.cluster.local:5432` and the `litellm` database |
| Config change not picked up by ArgoCD | `manifests/ai/00-litellm-configmap.yaml` was manually edited | Never edit that file directly — CI sync overwrites it; revert the manual edit and push `config/litellm-config.yaml` |

---

## License

[MIT](LICENSE) © andrelair-platform
