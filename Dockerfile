# ════════════════════════════════════════════════════════════════
# 🦞 HuggingClaw — OpenClaw Gateway for HuggingFace Spaces
# ════════════════════════════════════════════════════════════════
# Multi-stage build: uses pre-built OpenClaw image for fast builds

# ── Stage 1: Pull pre-built OpenClaw ──
FROM ghcr.io/openclaw/openclaw:latest AS openclaw

# ── Stage 2: Runtime ──
FROM node:22-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    ca-certificates \
    jq \
    curl \
    python3 \
    python3-pip \
    --no-install-recommends && \
    pip3 install --no-cache-dir --break-system-packages huggingface_hub && \
    rm -rf /var/lib/apt/lists/*

# Reuse existing node user (UID 1000)
RUN mkdir -p /home/node/app /home/node/.openclaw && \
    chown -R 1000:1000 /home/node

# Copy pre-built OpenClaw (skips npm install entirely — much faster!)
COPY --from=openclaw --chown=1000:1000 /app /home/node/.openclaw/openclaw-app

# Symlink openclaw CLI so it's available globally
RUN ln -s /home/node/.openclaw/openclaw-app/openclaw.mjs /usr/local/bin/openclaw 2>/dev/null || \
    npm install -g openclaw@latest

# Copy HuggingClaw files
COPY --chown=1000:1000 dns-fix.js /opt/dns-fix.js
COPY --chown=1000:1000 health-server.js /home/node/app/health-server.js
COPY --chown=1000:1000 iframe-fix.cjs /home/node/app/iframe-fix.cjs
COPY --chown=1000:1000 start.sh /home/node/app/start.sh
COPY --chown=1000:1000 keep-alive.sh /home/node/app/keep-alive.sh
COPY --chown=1000:1000 wa-guardian.js /home/node/app/wa-guardian.js
COPY --chown=1000:1000 workspace-sync.py /home/node/app/workspace-sync.py
RUN chmod +x /home/node/app/start.sh /home/node/app/keep-alive.sh

USER node

ENV HOME=/home/node \
    PATH=/home/node/.local/bin:/usr/local/bin:$PATH \
    NODE_OPTIONS="--require /opt/dns-fix.js"

WORKDIR /home/node/app

EXPOSE 7861

CMD ["/home/node/app/start.sh"]
