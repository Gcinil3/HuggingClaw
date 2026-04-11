# ── Stage 1: Pull pre-built OpenClaw ──
ARG OPENCLAW_VERSION=latest
FROM ghcr.io/openclaw/openclaw:${OPENCLAW_VERSION} AS openclaw

# ── Stage 2: Runtime (with Ollama) ──
FROM node:22-slim

# ── Install system dependencies (browser + deps) ──
RUN apt-get update && apt-get install -y \
    git \
    ca-certificates \
    jq \
    curl \
    python3 \
    python3-pip \
    chromium \
    libnss3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libdrm2 \
    libgbm1 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    libxkbcommon0 \
    libx11-6 \
    libxext6 \
    libxfixes3 \
    libasound2 \
    fonts-dejavu-core \
    fonts-liberation \
    fonts-noto-color-emoji \
    fonts-freefont-ttf \
    fonts-ipafont-gothic \
    fonts-wqy-zenhei \
    xfonts-scalable \
    zstd \
    tar \
    --no-install-recommends && \
    pip3 install --no-cache-dir --break-system-packages huggingface_hub && \
    curl -fsSL https://ollama.ai/install.sh | sh && \
    rm -rf /var/lib/apt/lists/*

# ── Create user & dirs ──
RUN mkdir -p /home/node/app /home/node/.openclaw /home/node/.ollama && \
    chown -R 1000:1000 /home/node

# ── Copy pre-built OpenClaw ──
COPY --from=openclaw --chown=1000:1000 /app /home/node/.openclaw/openclaw-app

# ── Add Playwright (isolated) ──
RUN mkdir -p /home/node/browser-deps && \
    cd /home/node/browser-deps && \
    npm init -y && \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --omit=dev playwright@1.59.1

# ── Symlink openclaw CLI ──
RUN ln -sf /home/node/.openclaw/openclaw-app/openclaw.mjs /usr/local/bin/openclaw || \
    npm install -g openclaw@${OPENCLAW_VERSION}

# ── Copy HuggingClaw files ──
COPY --chown=1000:1000 dns-fix.js /opt/dns-fix.js
COPY --chown=1000:1000 health-server.js /home/node/app/health-server.js
COPY --chown=1000:1000 iframe-fix.cjs /home/node/app/iframe-fix.cjs
COPY --chown=1000:1000 start.sh /home/node/app/start.sh
COPY --chown=1000:1000 wa-guardian.js /home/node/app/wa-guardian.js
COPY --chown=1000:1000 workspace-sync.py /home/node/app/workspace-sync.py
COPY --chown=1000:1000 ollama-init.sh /home/node/app/ollama-init.sh
RUN chmod +x /home/node/app/start.sh /home/node/app/ollama-init.sh

# ── Default Ollama_MODEL (optional override via user env) ──
ARG OLLAMA_MODEL="llama3"
ARG OLLAMA_BASE_URL="http://localhost:11434"

# ── Environment vars (user can override at runtime) ──
ENV OLLAMA_MODEL=${OLLAMA_MODEL} \
    OLLAMA_BASE_URL=${OLLAMA_BASE_URL} \
    USE_EXTERNAL_OLLAMA="false" \
    OLLAMA_TIMEOUT="30s" \
    HOME=/home/node \
    OPENCLAW_VERSION=${OPENCLAW_VERSION} \
    PATH=/home/node/.local/bin:/usr/local/bin:$PATH \
    NODE_PATH=/home/node/browser-deps/node_modules \
    NODE_OPTIONS="--require /opt/dns-fix.js" \
    OLLAMA_HOST="0.0.0.0:11434" \
    OLLAMA_ENABLED="false"

WORKDIR /home/node/app
USER node

EXPOSE 7860

CMD ["/home/node/app/start.sh"]
