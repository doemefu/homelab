#!/usr/bin/env bash
# Smoke test for the LiteLLM AI Gateway at ai.furchert.ch
#
# Usage:
#   LITELLM_BASE_URL=https://ai.furchert.ch \
#   LITELLM_MASTER_KEY=sk-... \
#   ./scripts/smoke-test-litellm.sh
#
# All 5 checks must pass. Exits non-zero on any failure.
# Run AFTER the Ansible playbooks complete and DNS has propagated.

set -euo pipefail

BASE_URL="${LITELLM_BASE_URL:-https://ai.furchert.ch}"
MASTER_KEY="${LITELLM_MASTER_KEY:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC} — $1"; }
fail() { echo -e "${RED}FAIL${NC} — $1"; exit 1; }

if [[ -z "$MASTER_KEY" ]]; then
  echo "Error: LITELLM_MASTER_KEY is not set."
  echo "Usage: LITELLM_BASE_URL=https://ai.furchert.ch LITELLM_MASTER_KEY=sk-... $0"
  exit 1
fi

command -v curl >/dev/null 2>&1 || { echo "Error: curl is required but not found."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not found. Install: brew install jq"; exit 1; }

# All requests share these timeouts so a misconfigured DNS / Tunnel / stalled
# upstream fails fast instead of hanging the run indefinitely.
# Probe/list endpoints: 5s connect, 15s overall. Completion endpoints: 5s connect,
# 60s overall (model inference can take >15s under load).
CURL_QUICK=(--connect-timeout 5 --max-time 15)
CURL_COMPLETION=(--connect-timeout 5 --max-time 60)

echo "Smoke testing LiteLLM at: $BASE_URL"
echo "---"

# 1. Liveness probe
echo "[1/5] Health check (liveness)..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/health/liveliness")
if [[ "$STATUS" == "200" ]]; then
  pass "GET /health/liveliness → $STATUS"
else
  fail "GET /health/liveliness → $STATUS (expected 200)"
fi

# 2. Auth rejection — unauthenticated request must return 401
echo "[2/5] Unauthenticated request rejection..."
STATUS=$(curl -s "${CURL_QUICK[@]}" -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"mistral-small","messages":[{"role":"user","content":"ping"}]}')
if [[ "$STATUS" == "401" ]]; then
  pass "Unauthenticated POST /v1/chat/completions → $STATUS"
else
  fail "Expected 401, got $STATUS (auth not enforced!)"
fi

# 3. Models list
echo "[3/5] Models list..."
RESPONSE=$(curl -s "$BASE_URL/v1/models" -H "Authorization: Bearer $MASTER_KEY")
for model in mistral-small mistral-large mistral-codestral; do
  if echo "$RESPONSE" | jq -e --arg id "$model" '.data[] | select(.id == $id)' > /dev/null; then
    pass "GET /v1/models contains $model"
  else
    fail "$model missing from /v1/models response"
  fi
done

# 4. Mistral Small completion
echo "[4/5] Mistral Small completion..."
RESPONSE=$(curl -s "${CURL_COMPLETION[@]}" -X POST "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"mistral-small","messages":[{"role":"user","content":"Reply with one word: pong"}],"max_tokens":10}')
if echo "$RESPONSE" | grep -q '"choices"'; then
  pass "Mistral Small completion → choices present"
else
  fail "Mistral Small completion failed: $RESPONSE"
fi

# 5. Mistral Codestral completion
echo "[5/5] Mistral Codestral completion..."
RESPONSE=$(curl -s "${CURL_COMPLETION[@]}" -X POST "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"mistral-codestral","messages":[{"role":"user","content":"Reply with one word: pong"}],"max_tokens":10}')
if echo "$RESPONSE" | grep -q '"choices"'; then
  pass "Mistral Codestral completion → choices present"
else
  fail "Mistral Codestral completion failed: $RESPONSE"
fi

echo "---"
echo -e "${GREEN}All checks passed.${NC} LiteLLM is operational at $BASE_URL"
echo ""
echo "Next steps:"
echo "  Dashboard: $BASE_URL/ui  (login with master key)"
echo "  Clients: point OpenAI-compatible base URL to $BASE_URL and use Authorization Bearer \$LITELLM_MASTER_KEY"
