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

echo "Smoke testing LiteLLM at: $BASE_URL"
echo "---"

# 1. Liveness probe
echo "[1/5] Health check (liveness)..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/health/liveliness")
[[ "$STATUS" == "200" ]] && pass "GET /health/liveliness → $STATUS" || fail "GET /health/liveliness → $STATUS (expected 200)"

# 2. Auth rejection — unauthenticated request must return 401
echo "[2/5] Unauthenticated request rejection..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST "$BASE_URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"mistral-small","messages":[{"role":"user","content":"ping"}]}')
[[ "$STATUS" == "401" ]] && pass "Unauthenticated POST /v1/chat/completions → $STATUS" || fail "Expected 401, got $STATUS (auth not enforced!)"

# 3. Models list
echo "[3/5] Models list..."
RESPONSE=$(curl -s "$BASE_URL/models" -H "Authorization: Bearer $MASTER_KEY")
echo "$RESPONSE" | grep -q '"mistral-small"' && pass "GET /models contains mistral-small" || fail "mistral-small missing from /models response"
echo "$RESPONSE" | grep -q '"claude-3-5-sonnet"' && pass "GET /models contains claude-3-5-sonnet" || fail "claude-3-5-sonnet missing from /models response"

# 4. Mistral completion
echo "[4/5] Mistral Small completion..."
RESPONSE=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"mistral-small","messages":[{"role":"user","content":"Reply with one word: pong"}],"max_tokens":10}')
echo "$RESPONSE" | grep -q '"choices"' && pass "Mistral Small completion → choices present" || fail "Mistral Small completion failed: $RESPONSE"

# 5. Anthropic completion via proxy
echo "[5/5] Anthropic claude-3-5-sonnet completion via proxy..."
RESPONSE=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-3-5-sonnet","messages":[{"role":"user","content":"Reply with one word: pong"}],"max_tokens":10}')
echo "$RESPONSE" | grep -q '"choices"' && pass "Anthropic proxy completion → choices present" || fail "Anthropic proxy completion failed: $RESPONSE"

echo "---"
echo -e "${GREEN}All checks passed.${NC} LiteLLM is operational at $BASE_URL"
echo ""
echo "Next steps:"
echo "  Dashboard: $BASE_URL/ui  (login with master key)"
echo "  Claude Code: set ANTHROPIC_BASE_URL=$BASE_URL and ANTHROPIC_AUTH_TOKEN=\$LITELLM_MASTER_KEY"
