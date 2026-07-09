# AI Gateway — 3-Tier Department Key Governance

Virtual keys are managed by LiteLLM and stored in PostgreSQL (`litellm` database on `postgresql-ai`).
This document is the authoritative reference for the key structure — changes are applied via the
LiteLLM admin API and reflected here.

## Tier Model

```
TIER 1 — Premium (Direction IT, Cybersécurité, Data & Analytics)
  Models allowed: all (gpt-4o, claude-sonnet, gemini-1.5-pro, nvidia-nemotron-70b, phi3-financial, ...)
  Monthly budget: €500 per key
  Rate limit: 200 RPM

TIER 2 — Standard (Finance, Actuariat, Souscription, Réassurance, Juridique, Transformation)
  Models allowed: gpt-4o-mini, phi4-mini, qwen3.5:4b, deepseek-r1:7b, phi3-financial,
                  gemini-2.0-flash, claude-haiku, llama3.2:1b
  Monthly budget: €100 per key
  Rate limit: 60 RPM

TIER 3 — Basic (Sinistres, Opérations, Audit, RH, Commercial, Services Généraux)
  Models allowed: phi4-mini, phi3-financial, llama3.2:1b, nomic-embed-text
  Monthly budget: €20 per key
  Rate limit: 20 RPM
```

## Department → Key Mapping

| Department | Tier | Key alias | Monthly cap |
|---|---|---|---|
| Direction IT / SI | 1 | `dept-it` | €500 |
| Direction Cybersécurité | 1 | `dept-cyber` | €500 |
| Direction Data & Analytics | 1 | `dept-data` | €500 |
| Finance | 2 | `dept-finance` | €100 |
| Actuariat | 2 | `dept-actuariat` | €100 |
| Souscription | 2 | `dept-souscription` | €100 |
| Réassurance | 2 | `dept-reassurance` | €100 |
| Juridique | 2 | `dept-juridique` | €100 |
| Direction Transformation | 2 | `dept-transformation` | €100 |
| Sinistres | 3 | `dept-sinistres` | €20 |
| Opérations | 3 | `dept-operations` | €20 |
| Audit | 3 | `dept-audit` | €20 |
| RH | 3 | `dept-rh` | €20 |
| Direction Commercial | 3 | `dept-commercial` | €20 |
| Services Généraux | 3 | `dept-services` | €20 |

## Enforcement mechanism

LiteLLM enforces three independent controls per key:

1. **Model allowlist** (`allowed_models`) — request rejected at admission if the requested model
   is not in the key's allowlist. HTTP 403 returned with no backend call made.

2. **Monthly spend cap** (`max_budget`) — LiteLLM tracks token cost in USD against the Prometheus
   exporter and PostgreSQL `litellm_budgets` table. Requests exceeding the cap receive HTTP 429.

3. **Rate limit** (`tpm_limit` / `rpm_limit`) — sliding-window counter per key. Excess requests
   receive HTTP 429 immediately with no token consumed.

## phi3-financial access

`phi3-financial` is whitelisted on **all tiers** (local-only model, zero cloud cost).
It is the default model for the Finance, Actuariat, and Sinistres departments.

Cloud models with cloud cost (gpt-4o, claude-sonnet, gemini-1.5-pro, nvidia-nemotron-70b)
are **Tier 1 only**.

## Audit trail

Every request is logged to Langfuse with:
- `key_alias` — which department key made the request
- `model` — which model was selected (after routing)
- `cost` — USD cost of the request
- `status` — success / failure / budget_exceeded

Cost aggregation visible in Grafana → AI Gateway Cost Dashboard (PostgreSQL SQL on `litellm_spend`).

## Apply a key change

```bash
# Port-forward LiteLLM admin API
kubectl --context minicloud port-forward -n ai svc/litellm 4000:4000 &

# Update a key's budget cap (example: Finance dept key)
curl -X PATCH http://localhost:4000/key/update \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key": "dept-finance", "max_budget": 150}'

# Verify
curl http://localhost:4000/key/info?key=dept-finance \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" | jq '.info | {max_budget, spend, models}'
```
