# REGISTRY / *_IMAGE can be overridden at build-time. The defaults point at
# Microsoft Container Registry (MCR) so the same Dockerfile works in:
#   - local `docker build` (no Docker Hub anonymous rate limits),
#   - public deploys via shared ACR Tasks,
#   - network-isolated deploys via private ACR Tasks agent pool, where the
#     Azure Firewall allow-list already permits `mcr.microsoft.com` and does
#     not allow `registry-1.docker.io`.
# To use upstream Docker Hub images (e.g. for slimmer Alpine variants in CI),
# pass `--build-arg REGISTRY=docker.io --build-arg NODE_IMAGE=library/node:20-alpine`.
ARG REGISTRY=mcr.microsoft.com
ARG NODE_IMAGE=devcontainers/javascript-node:20
ARG PYTHON_IMAGE=devcontainers/python:3.11-bullseye

FROM ${REGISTRY}/${NODE_IMAGE} AS frontend-builder

WORKDIR /app

RUN npm config set strict-ssl false

COPY frontend/package*.json ./
RUN npm ci --legacy-peer-deps --include=dev

COPY frontend/src/ ./src/
COPY frontend/public/ ./public/
COPY frontend/index.html ./
COPY frontend/vite.config.ts ./
COPY frontend/tsconfig.json ./
COPY frontend/tsconfig.node.json ./
COPY frontend/eslint.config.js ./
COPY frontend/.prettierrc ./
COPY frontend/.prettierignore ./

RUN npx --yes tsc && npx --yes vite build

# Stage 2: Python runtime (using Ubuntu 20.04 base to avoid OpenSSL 3 issues with speechsdk)
FROM ${REGISTRY}/${PYTHON_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    FLASK_APP=src/app.py \
    FLASK_ENV=production \
    PIP_TRUSTED_HOST="pypi.org files.pythonhosted.org pypi.python.org" \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONPATH=/app

# The mcr.microsoft.com/devcontainers/python:3.11-bullseye image ships with a
# yarnpkg apt source whose signing key is no longer trusted by current apt.
# We don't need yarn at runtime, so drop the source before `apt-get update` to
# avoid a hard failure on `NO_PUBKEY 62D54FD4003F6525` / unsigned repository.
RUN rm -f /etc/apt/sources.list.d/yarn.list \
    && apt-get update && apt-get install -y \
    build-essential \
    curl \
    ca-certificates \
    libasound2 \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash app

WORKDIR /app

COPY backend/requirements.txt ./
RUN pip install --no-cache-dir --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org -r requirements.txt

COPY --chown=app:app backend/src/ ./src/
COPY --chown=app:app data/scenarios/ ./data/scenarios/
COPY --chown=app:app data/graph-api-canned.json ./data/

COPY --from=frontend-builder --chown=app:app /app/static/ ./static/

USER app
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/api/config || exit 1

CMD ["python", "src/app.py"]