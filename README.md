# minicloud-litellm-custom

Custom LiteLLM image and AI Gateway configuration for the Minicloud platform.

## What this repo owns

| File | Purpose |
|---|---|
| `Dockerfile` | Patches on top of `ghcr.io/berriai/litellm-database:main-latest` (Prisma permissions, libatomic, google-generativeai) |
| `langfuse_prompt_handler.py` | LiteLLM `CustomLogger` — injects the Langfuse production prompt into every `phi3-financial` request |
| `config/litellm-config.yaml` | **Canonical AI Gateway configuration** — model routing, guardrails, cloud fallbacks, Presidio PII, Valkey cache |

## The config is source of truth here

All AI Gateway changes — add a model, tweak routing, change Presidio rules, adjust circuit breaker — are made by editing `config/litellm-config.yaml` and pushing to `main`.

CI automatically wraps it into a Kubernetes ConfigMap and pushes the result to [minicloud-gitops](https://github.com/andrelair-platform/minicloud-gitops) (`manifests/ai/00-litellm-configmap.yaml`). ArgoCD picks it up within 3 minutes and syncs the live cluster.

**Never edit `manifests/ai/00-litellm-configmap.yaml` directly in gitops** — the next CI run will overwrite it.

```
config/litellm-config.yaml   →  CI sync  →  minicloud-gitops/manifests/ai/00-litellm-configmap.yaml
langfuse_prompt_handler.py   →  CI sync  →  minicloud-gitops/manifests/ai/15-langfuse-prompt-handler-configmap.yaml
```

## Making a config change

1. Edit `config/litellm-config.yaml` (add model, change guardrail, adjust fallback, etc.)
2. `git commit -S -m "feat(config): ..."` and `git push origin main`
3. CI runs `sync-config.yml` → commits to minicloud-gitops with a GPG-signed commit
4. ArgoCD auto-syncs → LiteLLM ConfigMap updated in cluster
5. LiteLLM picks up the new config on next restart (or within the ConfigMap volume refresh window, ~1 min)

## Making a handler change

1. Edit `langfuse_prompt_handler.py`
2. Push to `main` — same CI flow as above

No image rebuild needed for handler-only changes; the handler is mounted as a ConfigMap volume at `/app/langfuse_prompt_handler.py`.

## Making an image change

Image changes (Dockerfile patches, new Python dependencies) require a rebuild:

1. Edit `Dockerfile`
2. Push to `main` — the `ci.yml` workflow builds, pushes to Harbor, cosign-signs, and bumps the image tag in gitops

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│  minicloud-litellm-custom (this repo)                      │
│                                                            │
│  config/litellm-config.yaml  ──CI──►  gitops ConfigMap    │
│  langfuse_prompt_handler.py  ──CI──►  gitops ConfigMap    │
│  Dockerfile                  ──CI──►  Harbor image         │
└────────────────────────────────────────────────────────────┘
         ▼ ArgoCD auto-sync (≤3 min)
┌────────────────────────────────────────────────────────────┐
│  Cluster (ai namespace)                                    │
│                                                            │
│  LiteLLM pod                                               │
│    /app/config.yaml          ← ConfigMap volume mount      │
│    /app/langfuse_prompt_handler.py  ← ConfigMap subPath    │
│    harbor.../litellm:<sha>   ← image tag from gitops       │
└────────────────────────────────────────────────────────────┘
```

## Security notes

- `phi3-financial` is **local-only**. Sensitive financial data must never leave the cluster for this model. It is routed exclusively to on-premise Ollama instances.
- Cloud models (GPT-4o, Claude, Gemini) are gated behind Presidio PII masking at the `pre_call` guardrail stage.
- API keys (`OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, etc.) are injected from Vault via External Secrets Operator — never stored in this repo.

## CI secrets required

| Secret | Used by |
|---|---|
| `GITOPS_TOKEN` | Push to minicloud-gitops |
| `GPG_PRIVATE_KEY` | Sign commits to minicloud-gitops |
| `HARBOR_USER` / `HARBOR_PASSWORD` | Push Docker image to Harbor |
