ARG LITELLM_VERSION=1.90.3-prisma-v3
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
