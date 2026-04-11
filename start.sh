#!/bin/bash
set -e

# ════════════════════════════════════════════════════════════════
# HuggingClaw — OpenClaw Gateway for HF Spaces with Ollama Support
# ════════════════════════════════════════════════════════════════

# ── Startup Banner ──
OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"
WHATSAPP_ENABLED="${WHATSAPP_ENABLED:-false}"
WHATSAPP_ENABLED_NORMALIZED=$(printf '%s' "$WHATSAPP_ENABLED" | tr '[:upper:]' '[:lower:]')
SYNC_INTERVAL="${SYNC_INTERVAL:-180}"
OLLAMA_ENABLED="${OLLAMA_ENABLED:-false}"
OLLAMA_MODEL="${OLLAMA_MODEL:-tinyllama}"
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"
echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║          🦞 HuggingClaw Gateway          ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# ── Validate required secrets ──
ERRORS=""

# LLM_API_KEY is only required for cloud LLMs — Ollama (local) doesn't need it
if [ "$OLLAMA_ENABLED" != "true" ] && [ -z "$OLLAMA_BASE_URL" ]; then
  if [ -z "$LLM_API_KEY" ]; then
    ERRORS="${ERRORS}  ❌ LLM_API_KEY is not set\n"
  fi
fi

# Allow Ollama to auto-assign model if not set
if [ "$OLLAMA_ENABLED" != "true" ]; then
  if [ -z "$LLM_MODEL" ]; then
    ERRORS="${ERRORS}  ❌ LLM_MODEL is not set (e.g. google/gemini-2.5-flash, anthropic/claude-sonnet-4-5, openai/gpt-4)\n"
  fi
else
  # Auto-assign default Ollama model
  export LLM_MODEL="${OLLAMA_MODEL:-tinyllama}"
  echo "  ⚠️  LLM_MODEL not set — using fallback: $LLM_MODEL (Ollama)"
fi

if [ -z "$GATEWAY_TOKEN" ]; then
  ERRORS="${ERRORS}  ❌ GATEWAY_TOKEN is not set (generate: openssl rand -hex 32)\n"
fi

if [ -n "$ERRORS" ]; then
  echo "Missing required secrets:"
  echo -e "$ERRORS"
  echo "Add them in HF Spaces → Settings → Secrets"
  exit 1
fi

# ── Ollama Setup ──
if [ "$OLLAMA_ENABLED" = "true" ]; then
  echo "🧠 Ollama mode enabled"
  echo "   Model: $LLM_MODEL"
  echo "   Base URL: $OLLAMA_BASE_URL"
  
  # Check if using external Ollama or internal
  if [ "$USE_EXTERNAL_OLLAMA" != "true" ]; then
    echo "🚀 Starting internal Ollama server..."
    
    # Start Ollama in background and wait for it
    export OLLAMA_HOST="127.0.0.1:11434"
    export OLLAMA_NUM_THREADS=1
    export OLLAMA_MAX_LOADED_MODELS=1
    export OLLAMA_ROOT="/home/node/.ollama"
    mkdir -p "$OLLAMA_ROOT" && chmod 700 "$OLLAMA_ROOT"
    
    # Start Ollama server
    echo "🧠 Starting Ollama server..."
    nohup ollama serve > "$OLLAMA_ROOT/ollama.log" 2>&1 &
    OLLAMA_PID=$!
    echo "🦞 Ollama started (PID: $OLLAMA_PID)"
    
    # Wait for health endpoint
    echo "⏳ Waiting for Ollama API..."
    for i in {1..60}; do
      if curl -sf "http://127.0.0.1:11434/api/health" > /dev/null 2>&1; then
        echo "✅ Ollama is healthy!"
        break
      fi
      if [ $i -eq 30 ]; then
        echo "⚠️  Still waiting... (log: $(tail -1 "$OLLAMA_ROOT/ollama.log" 2>/dev/null || echo 'none'))"
      fi
      sleep 1
    done
    
    # Pull the model if not already present
    echo "⏳ Ensuring Ollama model '$LLM_MODEL' is available..."
    if ! ollama list 2>/dev/null | grep -q "^$LLM_MODEL"; then
      echo "⬇️  Pulling model: $LLM_MODEL (this may take a while)..."
      ollama pull "$LLM_MODEL" || {
        echo "⚠️  Failed to pull model $LLM_MODEL. Check available models."
        ollama list 2>/dev/null || echo "Cannot list models"
      }
    else
      echo "✅ Model $LLM_MODEL already available"
    fi
  else
    echo "ℹ️  Using external Ollama at $OLLAMA_BASE_URL"
    # Verify external Ollama is reachable
    if curl -sf "$OLLAMA_BASE_URL/api/health" > /dev/null 2>&1; then
      echo "✅ External Ollama health check passed"
    else
      echo "⚠️  Warning: Cannot reach external Ollama at $OLLAMA_BASE_URL"
    fi
  fi
  
  # Set LLM provider to Ollama
  export LLM_PROVIDER="ollama"
else
  echo "☁️  Cloud LLM mode"
  echo "   Model: $LLM_MODEL"
fi

# ── Generate OpenClaw Configuration ──
echo ""
echo "📝 Generating OpenClaw configuration..."

CONFIG_DIR="/home/node/.openclaw"
mkdir -p "$CONFIG_DIR"

# Create openclaw.json configuration
cat > "$CONFIG_DIR/openclaw.json" << EOF
{
  "gateway": {
    "token": "$GATEWAY_TOKEN",
    "port": 7860
  },
  "llm": {
    "provider": "${LLM_PROVIDER:-auto}",
    "model": "$LLM_MODEL",
    "apiKey": "${LLM_API_KEY:-}",
    "baseUrl": "${OLLAMA_ENABLED:+$OLLAMA_BASE_URL}"
  },
  "channels": {
    "telegram": {
      "enabled": ${TELEGRAM_BOT_TOKEN:+true:-false},
      "botToken": "${TELEGRAM_BOT_TOKEN:-}",
      "allowedUserIds": [${TELEGRAM_USER_ID:+\"$TELEGRAM_USER_ID\"}${TELEGRAM_USER_IDS:+,\"$TELEGRAM_USER_IDS\"}]
    },
    "whatsapp": {
      "enabled": $WHATSAPP_ENABLED_NORMALIZED
    }
  },
  "workspace": {
    "path": "/home/node/.openclaw/workspace",
    "sync": {
      "enabled": ${HF_TOKEN:+true:-false},
      "interval": $SYNC_INTERVAL,
      "hfUsername": "${HF_USERNAME:-}",
      "hfToken": "${HF_TOKEN:-}",
      "datasetName": "${BACKUP_DATASET_NAME:-huggingclaw-backup}"
    }
  }
}
EOF

echo "✅ Configuration saved to $CONFIG_DIR/openclaw.json"

# ── Workspace Setup ──
WORKSPACE_DIR="/home/node/.openclaw/workspace"
mkdir -p "$WORKSPACE_DIR"

# Restore workspace from HF Dataset if credentials provided
if [ -n "$HF_TOKEN" ] && [ -n "$HF_USERNAME" ]; then
  echo ""
  echo "💾 Restoring workspace from HuggingFace Dataset..."
  python3 /home/node/app/workspace-sync.py restore || {
    echo "⚠️  Workspace restore failed, continuing with empty workspace"
  }
fi

# ── Start Background Services ──
echo ""
echo "🔧 Starting background services..."

# Start health server for uptime monitoring
node /home/node/app/health-server.js &
HEALTH_PID=$!
echo "✅ Health server started (PID: $HEALTH_PID)"

# Start WhatsApp guardian if enabled
if [ "$WHATSAPP_ENABLED_NORMALIZED" = "true" ]; then
  node /home/node/app/wa-guardian.js &
  WA_PID=$!
  echo "✅ WhatsApp guardian started (PID: $WA_PID)"
fi

# Start workspace sync if HF credentials provided
if [ -n "$HF_TOKEN" ] && [ -n "$HF_USERNAME" ]; then
  echo "🔄 Starting workspace auto-sync (interval: ${SYNC_INTERVAL}s)"
  while true; do
    sleep "$SYNC_INTERVAL"
    python3 /home/node/app/workspace-sync.py sync || true
  done &
  SYNC_PID=$!
  echo "✅ Workspace sync started (PID: $SYNC_PID)"
fi

# ── Launch OpenClaw Gateway ──
echo ""
echo "🚀 Launching OpenClaw Gateway..."
echo "   Version: $OPENCLAW_VERSION"
echo "   Port: 7860"
echo "   Control UI: http://localhost:7860"
echo ""
echo "════════════════════════════════════════════"
echo "  🦞 HuggingClaw is ready!"
echo "════════════════════════════════════════════"
echo ""

# Execute OpenClaw (config file path as positional argument)
exec openclaw gateway "$CONFIG_DIR/openclaw.json"
