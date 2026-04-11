#!/bin/bash
set -e

echo "🚀 HuggingClaw: Initializing Ollama..."

# Skip if external Ollama configured
if [ "$USE_EXTERNAL_OLLAMA" = "true" ]; then
  echo "ℹ️ Using external Ollama at $OLLAMA_BASE_URL"
  if curl -sf "$OLLAMA_BASE_URL/api/health" > /dev/null 2>&1; then
    echo "✅ External Ollama health check ok"
  else
    echo "⚠️ Failed to reach external Ollama at $OLLAMA_BASE_URL"
  fi
  exit 0
fi

export OLLAMA_HOST="127.0.0.1:11434"
export OLLAMA_NUM_THREADS=1
export OLLAMA_MAX_LOADED_MODELS=1
export OLLAMA_ROOT="/home/node/.ollama"

# Ensure Ollama root exists and is writable
export OLLAMA_ROOT="${OLLAMA_ROOT:-/home/node/.ollama}"
mkdir -p "$OLLAMA_ROOT" && chmod 700 "$OLLAMA_ROOT"

# Set host explicitly to allow loopback + avoid BIND errors in constrained env
export OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
echo "⚙️ Ollama host: $OLLAMA_HOST"

# Check if already running (e.g., restart)
if pgrep -x ollama > /dev/null 2>&1; then
  echo "🦞 Ollama already running"
  exit 0
fi

# Terraform startup script
echo "🧠 Starting Ollama server..."
nohup ollama serve > "$OLLAMA_ROOT/ollama.log" 2>&1 &
OLLAMA_PID=$!
echo "🦞 Ollama started (PID: $OLLAMA_PID)"

# Give Ollama a moment to initialize sockets
sleep 2

# Wait for health endpoint — increase patience (up to 90s)
echo "⏳ Waiting for Ollama API (/api/health)..."
for i in {1..90}; do
  # Try both host:port AND localhost (some builds prefer .0.0.0 vs 127)
  for try_host in 127.0.0.1 localhost; do
    if curl -sf "http://$try_host:11434/api/health" > /dev/null 2>&1; then
      echo "✅ Ollama is healthy at http://$try_host:11434!"
      exit 0
    fi
  done

  # While waiting, show startup progress (last 2 lines of log)
  if [ -f "$OLLAMA_ROOT/ollama.log" ] && (( i % 10 == 0 )); then
    echo "   ... still starting — last log lines:"
    tail -2 "$OLLAMA_ROOT/ollama.log" | sed 's/^/   /'
  fi

  sleep 1
done


# Timeout: show full log and check if process is still running
if ! kill -0 $OLLAMA_PID 2>/dev/null; then
  echo "❌ Ollama process died!"
else
  echo "❌ Ollama failed to start within 90s!"
fi
echo "Log output:"
cat "$OLLAMA_ROOT/ollama.log" 2>/dev/null || echo "(no log file)"
exit 1
