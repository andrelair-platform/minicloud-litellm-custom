ARG LITELLM_VERSION=1.90.3-prisma-v4
FROM ghcr.io/berriai/litellm-database:main-latest

# The image pre-downloads Prisma engine binaries to /root/.cache (mode 700, root-only).
# prisma-client-py's generated BINARY_PATHS dict hardcodes those paths. When running
# as non-root (UID 1000 in k8s), Path.exists() on those paths raises PermissionError
# before PRISMA_QUERY_ENGINE_BINARY can override anything. Fix: make the cache world-
# readable so the hardcoded paths are directly accessible without any env var overrides.
RUN chmod -R 755 /root /root/.cache /root/.cache/prisma-python

# libatomic1: required by the Node.js binary that prisma-client-py downloads at
# runtime to run Prisma CLI migrations. Missing from the base image — causes
# "cannot open shared object file: libatomic.so.1" on nodes without it on the host.
RUN apk add --no-cache libatomic

# detect-secrets and redis are already present in the base venv.
# google-generativeai is missing — bootstrap pip via ensurepip then install.
RUN /app/.venv/bin/python -m ensurepip && \
    /app/.venv/bin/python -m pip install --no-cache-dir 'google-generativeai>=0.8.0'

# LiteLLM bug: load_config() assigns `general_settings = config.get("general_settings", {})`
# into a local variable (no `global general_settings` in scope). The module-level dict
# stays empty, so auth_utils.route_in_additonal_public_routes() always finds public_routes=[]
# and /v1/models (and any other custom public route) stays 401.
# Fix: after the local assignment, sync the public_routes key into the module-level dict.
RUN /app/.venv/bin/python - <<'PYEOF'
import sys

proxy_server = "/app/.venv/lib/python3.13/site-packages/litellm/proxy/proxy_server.py"

with open(proxy_server) as f:
    src = f.read()

old = (
    '        general_settings = config.get("general_settings", {})\n'
    '        if general_settings is None:\n'
    '            general_settings = {}'
)
new = (
    '        general_settings = config.get("general_settings", {})\n'
    '        if general_settings is None:\n'
    '            general_settings = {}\n'
    '        # Sync auth-related keys to module-level dict (workaround: general_settings\n'
    '        # is a local var here — not in global declarations — so auth middleware\n'
    '        # cannot see public_routes without this explicit sync).\n'
    '        import litellm.proxy.proxy_server as _ps\n'
    '        for _k in ("public_routes",):\n'
    '            if _k in general_settings:\n'
    '                _ps.general_settings[_k] = general_settings[_k]'
)

if old not in src:
    print("ERROR: patch target not found — check proxy_server.py version", file=sys.stderr)
    sys.exit(1)

patched = src.replace(old, new, 1)

with open(proxy_server, "w") as f:
    f.write(patched)

print("proxy_server.py patched: public_routes now synced to module-level general_settings")
PYEOF
