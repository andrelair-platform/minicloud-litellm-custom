ARG LITELLM_VERSION=1.90.3-prisma-v5
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

# LiteLLM open-source limitation: route_in_additonal_public_routes() is gated on
# premium_user — `if premium_user is not True: return False` short-circuits before
# checking public_routes, making the config key a no-op in the community edition.
# Two-part fix:
#   1. auth_utils.py: remove the premium_user gate so public_routes works for all tiers
#   2. proxy_server.py: sync public_routes from config's local general_settings into the
#      module-level dict (load_config uses a local var without `global general_settings`)
RUN /app/.venv/bin/python - <<'PYEOF'
import sys

auth_utils = "/app/.venv/lib/python3.13/site-packages/litellm/proxy/auth/auth_utils.py"
proxy_server = "/app/.venv/lib/python3.13/site-packages/litellm/proxy/proxy_server.py"

# --- Patch 1: remove premium_user gate in route_in_additonal_public_routes ---
with open(auth_utils) as f:
    src = f.read()

old1 = (
    '    try:\n'
    '        if premium_user is not True:\n'
    '            return False\n'
    '        if general_settings is None:\n'
    '            return False\n'
    '\n'
    '        routes_defined = general_settings.get("public_routes", [])'
)
new1 = (
    '    try:\n'
    '        if general_settings is None:\n'
    '            return False\n'
    '\n'
    '        routes_defined = general_settings.get("public_routes", [])'
)

if old1 not in src:
    print("ERROR: auth_utils patch target not found", file=sys.stderr)
    sys.exit(1)

with open(auth_utils, "w") as f:
    f.write(src.replace(old1, new1, 1))
print("auth_utils.py patched: removed premium_user gate from route_in_additonal_public_routes")

# --- Patch 2: sync public_routes from local to module-level general_settings ---
with open(proxy_server) as f:
    src = f.read()

old2 = (
    '        general_settings = config.get("general_settings", {})\n'
    '        if general_settings is None:\n'
    '            general_settings = {}'
)
new2 = (
    '        general_settings = config.get("general_settings", {})\n'
    '        if general_settings is None:\n'
    '            general_settings = {}\n'
    '        # Sync public_routes into module-level dict so auth_utils can read it.\n'
    '        # load_config() has no `global general_settings`, so the local var never\n'
    '        # reaches the module level without this explicit mutation.\n'
    '        import litellm.proxy.proxy_server as _ps\n'
    '        if "public_routes" in general_settings:\n'
    '            _ps.general_settings["public_routes"] = general_settings["public_routes"]'
)

if old2 not in src:
    print("ERROR: proxy_server patch target not found", file=sys.stderr)
    sys.exit(1)

with open(proxy_server, "w") as f:
    f.write(src.replace(old2, new2, 1))
print("proxy_server.py patched: public_routes synced to module-level general_settings")
PYEOF
