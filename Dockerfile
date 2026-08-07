# syntax=docker/dockerfile:1@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89

# Build arguments for versioning
ARG BUILD_TIME=unknown
ARG GIT_SHA=unknown
ARG VERSION=dev
ARG RELEASE_CHANNEL=dev

# Stage 1: Build frontend
# Pin to digest for reproducible builds (Dependabot will update this)
FROM node:24-alpine@sha256:d32cdf619f63fe0471182d08996dd516c6275bb5fd31ae06e55a570bd9e1ad43 AS frontend-builder

WORKDIR /app/frontend

# Copy package files
COPY frontend/package*.json ./

# Install dependencies
RUN npm ci

# Copy frontend source
COPY frontend/ ./

# Build frontend
RUN npm run build

# Stage 2: Build Python dependencies
# Use Chainguard's dev image which includes pip and build tools
# Pin to digest for reproducible builds (Dependabot will update this)
FROM cgr.dev/chainguard/python:latest-dev@sha256:7b79c054afd14f566d1d52ea1d4d037267ec8570efedbc6ead779d89ba943abe AS python-builder

WORKDIR /app

# Copy requirements (PyPI packages with hashes + VCS packages)
COPY requirements/base.txt requirements/vcs.txt ./requirements/

# Install Python dependencies to a virtual environment
# This allows us to copy just the installed packages to the runtime image
# PyPI packages are hash-verified for supply chain security
# VCS packages (monarchmoney) are installed separately without hash verification
RUN python -m venv /app/venv && \
    /app/venv/bin/pip install --no-cache-dir --upgrade pip && \
    /app/venv/bin/pip install --no-cache-dir --require-hashes -r requirements/base.txt && \
    /app/venv/bin/pip install --no-cache-dir --no-deps -r requirements/vcs.txt

# Stage 3: Runtime with minimal Chainguard image
# This image has 0-5 CVEs typically vs 800+ in python:3.12-slim
# Pin to digest for reproducible builds (Dependabot will update this)
FROM cgr.dev/chainguard/python:latest@sha256:cc8d5c94686633e8affbaf52ac4e6c739544fb8a7f69c1e7091adf1a312f30b8

# Re-declare build args for this stage
ARG BUILD_TIME=unknown
ARG GIT_SHA=unknown
ARG VERSION=dev
ARG RELEASE_CHANNEL=dev

# Set environment variables for the application
ENV BUILD_TIME=${BUILD_TIME}
ENV GIT_SHA=${GIT_SHA}
ENV APP_VERSION=${VERSION}
ENV RELEASE_CHANNEL=${RELEASE_CHANNEL}

# Chainguard images run as non-root by default (UID 65532)
# No need to create a user

WORKDIR /app

# Copy virtual environment from builder (owned by nonroot user)
COPY --from=python-builder --chown=65532:65532 /app/venv /app/venv

# Set PATH to use the virtual environment
ENV PATH="/app/venv/bin:$PATH"

# Copy Python source (owned by nonroot user)
COPY --chown=65532:65532 *.py ./
COPY --chown=65532:65532 blueprints/ ./blueprints/
COPY --chown=65532:65532 services/ ./services/
COPY --chown=65532:65532 core/ ./core/

# Copy state module with nonroot ownership (UID 65532) so app can write data files
# Note: /app/state should be mounted as a volume for persistent data
# Docker: docker run -v eclosion-data:/app/state ...
COPY --chown=65532:65532 state/ ./state/

# Copy built frontend from builder stage (owned by nonroot user)
COPY --from=frontend-builder --chown=65532:65532 /app/frontend/dist ./static

# Expose port
EXPOSE 5001

# Override Chainguard's default entrypoint to use venv Python with installed packages
ENTRYPOINT ["/app/venv/bin/python"]
CMD ["app.py"]
