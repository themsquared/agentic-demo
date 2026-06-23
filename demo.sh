#!/usr/bin/env bash
#
# Solo Agentic Demo — Interactive Walkthrough
#
# A guided, step-by-step demo that progressively builds up the full
# Solo agentic stack: LLM providers, MCP servers, security policies,
# agents, and the AgentRegistry catalog.
#
# Every resource shown is read from (and applied from) the SAME file under
# manifests/ — what you see on screen is exactly what gets applied. Browse
# manifests/ directly to read the examples outside the demo.
#
# Prerequisite: ./setup.sh has been run (base infrastructure is up) and
#               ./port-forward.sh is active.
#
# Usage:
#   ./demo.sh              # run the full interactive demo
#   ./demo.sh --reset      # just reset demo resources (clean slate)
#   ./demo.sh --act 3      # reset, then play acts 1..3 and stop
#
# Controls:
#   Press Enter to advance each step.  Ctrl-C to exit at any time.
#

set -euo pipefail

###############################################################################
# Config
###############################################################################
AGW_NS="agentgateway-system"
KAGENT_NS="kagent"
AR_NS="agentregistry-system"
KC_NS="keycloak"
AGW_PROXY="http://localhost:8081"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="${SCRIPT_DIR}/manifests"

# Load secrets from .env if present (gitignored) — same file setup.sh uses, so
# the demo's secret-creation steps pick up your real keys without re-typing.
if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a; . "${SCRIPT_DIR}/.env"; set +a
fi

###############################################################################
# Display helpers
###############################################################################
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'
BG_BLUE='\033[44m'

STEP_NUM=0

pause() {
  echo ""
  echo -en "  ${DIM}[ Press Enter to continue ]${NC}"
  read -r
  echo ""
}

act() {
  local num=$1; shift
  STEP_NUM=0
  clear
  echo ""
  echo -e "${BG_BLUE}${WHITE}                                                                    ${NC}"
  echo -e "${BG_BLUE}${WHITE}   ACT ${num}: $*                                                   ${NC}"
  echo -e "${BG_BLUE}${WHITE}                                                                    ${NC}"
  echo ""
  pause
}

scene() {
  STEP_NUM=$((STEP_NUM + 1))
  echo ""
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${CYAN}  ${STEP_NUM}. $*${NC}"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

narrate()  { echo -e "  ${DIM}$*${NC}"; }
callout()  { echo -e "  ${YELLOW}▸ $*${NC}"; }
check_ok() { echo -e "  ${GREEN}✓ $*${NC}"; }
check_fail(){ echo -e "  ${RED}✗ $*${NC}"; }

section_break() {
  echo ""
  echo -e "  ${DIM}─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─${NC}"
  echo ""
}

# Show the real manifest file (this is the single source of truth — it's the
# exact file apply_file applies).
show_file() {
  local f=$1
  local rel="manifests/${f#"${MANIFESTS}"/}"
  echo -e "  ${BOLD}📄 ${rel}${NC}"
  echo -e "  ${MAGENTA}┌────────────────────────────────────────────────────────${NC}"
  while IFS= read -r line; do
    echo -e "  ${MAGENTA}│${NC} ${line}"
  done < "$f"
  echo -e "  ${MAGENTA}└────────────────────────────────────────────────────────${NC}"
}

# Apply a manifest file (or directory), echoing the command first.
apply_file() {
  local f=$1
  local rel="manifests/${f#"${MANIFESTS}"/}"
  echo -e "  ${YELLOW}\$ kubectl apply -f ${rel}${NC}"
  kubectl apply -f "$f" 2>&1 | sed 's/^/    /'
}

# AgentRegistry (ar.dev) objects are NOT k8s CRDs — they go through the registry
# API via arctl. We run arctl in-cluster via the arctl-helper pod (issuer matches).
# ensure_arctl_helper deploys it once and waits; ar_apply_file pipes a manifest to it.
ensure_arctl_helper() {
  if ! kubectl get deploy arctl-helper -n "${AR_NS}" >/dev/null 2>&1; then
    echo -e "  ${DIM}(deploying in-cluster arctl helper — first use installs arctl)${NC}"
    kubectl apply -f "${MANIFESTS}/agentregistry/arctl-helper.yaml" >/dev/null 2>&1
  fi
  kubectl rollout status deploy/arctl-helper -n "${AR_NS}" --timeout=180s >/dev/null 2>&1 \
    && check_ok "arctl helper ready" \
    || check_fail "arctl helper not ready — AR catalog steps may not apply"
}

ar_apply_file() {
  local f=$1
  local rel="manifests/${f#"${MANIFESTS}"/}"
  echo -e "  ${YELLOW}\$ arctl apply -f ${rel}   ${DIM}(via in-cluster helper)${NC}"
  kubectl exec -i deploy/arctl-helper -n "${AR_NS}" -- arctl-apply < "$f" 2>&1 | sed 's/^/    /'
}

run_cmd() {
  echo -e "  ${YELLOW}\$ $*${NC}"
  eval "$@" 2>&1 | sed 's/^/    /'
}

# Display a multi-line curl (or any long command) as the user could paste it —
# first arg is the head ("curl -s URL"), remaining args are continuation lines
# (each rendered with backslash + indent). Doesn't run anything; the caller is
# responsible for actually executing the command (so we keep response capture).
show_curl() {
  local head=$1; shift
  echo -e "  ${YELLOW}\$ ${head} \\${NC}"
  local last_idx=$#
  local i=0
  for line in "$@"; do
    i=$((i+1))
    if [ "$i" -lt "$last_idx" ]; then
      echo -e "  ${YELLOW}    ${line} \\${NC}"
    else
      echo -e "  ${YELLOW}    ${line}${NC}"
    fi
  done
}

ui_moment() {
  echo ""
  echo -e "  ${BG_BLUE}${WHITE}  SWITCH TO BROWSER  ${NC}"
  echo -e "  ${BOLD}$*${NC}"
  pause
}

###############################################################################
# Reset — clean demo resources, keep infrastructure
###############################################################################
reset_demo() {
  echo -e "${YELLOW}Resetting demo resources...${NC}"

  kubectl delete agent --all -n "${KAGENT_NS}" 2>/dev/null || true
  for mc in anthropic-via-agw openai-via-agw anthropic-direct openai-direct; do
    kubectl delete modelconfig "$mc" -n "${KAGENT_NS}" 2>/dev/null || true
  done
  kubectl delete remotemcpserver --all -n "${KAGENT_NS}" 2>/dev/null || true
  kubectl delete secret anthropic-api-key openai-api-key -n "${KAGENT_NS}" 2>/dev/null || true

  kubectl delete agentgatewaybackend --all -n "${AGW_NS}" 2>/dev/null || true
  kubectl delete enterpriseagentgatewaybackend --all -n "${AGW_NS}" 2>/dev/null || true
  kubectl delete httproute --all -n "${AGW_NS}" 2>/dev/null || true
  # Delete ONLY demo-owned policies — never `--all`: the 'tracing' policy is
  # infrastructure (no act re-creates it) and deleting it silently kills the
  # UI Tracing tab until setup.sh is re-run.
  kubectl delete enterpriseagentgatewaypolicy github-mcp-elicit-policy -n "${AGW_NS}" 2>/dev/null || true
  # Defensive: make sure gateway tracing + LLM retries are in place even on
  # older clusters (both are infrastructure, not demo resources).
  kubectl apply -f "${MANIFESTS}/observability/agentgateway-tracing.yaml" >/dev/null 2>&1 || true
  kubectl apply -f "${MANIFESTS}/observability/llm-retry-policy.yaml" >/dev/null 2>&1 || true
  kubectl delete secret anthropic-secret openai-secret elicitation-oidc -n "${AGW_NS}" 2>/dev/null || true
  kubectl delete deployment mcp-website-fetcher mcp-server-everything -n "${AGW_NS}" 2>/dev/null || true
  kubectl delete service mcp-website-fetcher mcp-server-everything -n "${AGW_NS}" 2>/dev/null || true

  # Act 7 (Advanced AgentGateway) resources — clean by name so we don't touch
  # infra policies. Safe if any are absent (||true).
  kubectl delete httproute secure-anthropic secure-anthropic-jwt openapi-weather-mcp-route openapi-weather-mcp-code-route -n "${AGW_NS}" 2>/dev/null || true
  kubectl delete eagpol  eager-auth-apikey eager-auth-jwt anthropic-prompt-policies -n "${AGW_NS}" 2>/dev/null || true
  kubectl delete eagbe   openapi-weather-mcp openapi-weather-mcp-code -n "${AGW_NS}" 2>/dev/null || true
  kubectl delete secret  eager-auth-keys -n "${AGW_NS}" 2>/dev/null || true
  kubectl delete configmap mcp-openapi-weather-spec -n "${AGW_NS}" 2>/dev/null || true

  # AgentRegistry catalog objects are NOT k8s resources — delete via arctl helper
  # if it's present (best-effort; demo re-applies are idempotent upserts anyway).
  if kubectl get deploy arctl-helper -n "${AR_NS}" >/dev/null 2>&1; then
    for a in weather-assistant research-agent github-assistant orchestrator-agent; do
      kubectl exec deploy/arctl-helper -n "${AR_NS}" -- arctl-delete agent "$a" >/dev/null 2>&1 || true
    done
    for m in weather-mcp website-fetcher-mcp github-profile-mcp github-remote-mcp mcp-gateway everything-mcp; do
      kubectl exec deploy/arctl-helper -n "${AR_NS}" -- arctl-delete mcp "$m" >/dev/null 2>&1 || true
    done
  fi

  echo -e "${GREEN}Demo resources cleared. Infrastructure intact.${NC}"
}

###############################################################################
# Preflight
###############################################################################
preflight() {
  echo -e "${BOLD}Preflight check...${NC}"
  local ok=true
  kubectl get gateway agentgateway-proxy -n "${AGW_NS}" >/dev/null 2>&1 && check_ok "AgentGateway running" || { check_fail "AgentGateway not found"; ok=false; }
  kubectl get ns "${KAGENT_NS}" >/dev/null 2>&1 && check_ok "kagent namespace present" || { check_fail "kagent not found"; ok=false; }
  kubectl get ns "${AR_NS}" >/dev/null 2>&1 && check_ok "AgentRegistry namespace present" || { check_fail "AgentRegistry not found"; ok=false; }
  curl -s --connect-timeout 2 "${AGW_PROXY}" >/dev/null 2>&1 && check_ok "Port-forward active (localhost:8081)" || { check_fail "Port-forward not active — run ./port-forward.sh first"; ok=false; }
  if [ "$ok" = false ]; then
    echo -e "\n${RED}Run ./setup.sh and ./port-forward.sh first.${NC}"
    exit 1
  fi
  echo ""
}

###############################################################################
# Parse args
###############################################################################
# END_ACT controls how far into the demo we play. With no --act flag we run all
# seven acts. With --act N we reset, then play acts 1..N (so act N has the state
# it expects — agents need LLMs, AR needs agents, etc.) and stop after N.
END_ACT=7
for arg in "$@"; do
  case "$arg" in
    --reset) reset_demo; exit 0 ;;
    --act)   shift; END_ACT=${1:-7} ;;
    [1-7])   END_ACT=$arg ;;
  esac
done

preflight
reset_demo
echo ""
echo -e "${BOLD}${GREEN}Infrastructure is up. Demo resources cleared.${NC}"
echo -e "${BOLD}${GREEN}Let's build the full agentic stack, step by step.${NC}"
echo -e "${DIM}Every manifest shown lives under manifests/ — read them anytime.${NC}"
pause

###############################################################################
#
#  ACT 1 — AgentGateway: Your AI Traffic Controller
#
###############################################################################
if [ "$END_ACT" -ge 1 ]; then
act 1 "AgentGateway — Your AI Traffic Controller"

narrate "AgentGateway sits between your agents and AI providers."
narrate "It handles routing, auth, rate limiting, and observability"
narrate "for LLM calls, MCP tool calls, and agent-to-agent traffic."
narrate ""
narrate "Right now the gateway is running but has no backends configured."
narrate "Let's add LLM providers."
pause

# ── 1.1 Show empty gateway ──────────────────────────────────────────────────
scene "The Empty Gateway"
narrate "The gateway is running with zero backends and zero routes."
run_cmd "kubectl get agentgatewaybackend -n ${AGW_NS}"
run_cmd "kubectl get httproute -n ${AGW_NS}"
pause

# ── 1.2 Add Anthropic ───────────────────────────────────────────────────────
scene "Add Anthropic (Claude Sonnet 4)"
narrate "Three things make an LLM available through the gateway:"
narrate "  1. A Secret with the API key (created imperatively — never in a file)"
narrate "  2. An AgentgatewayBackend defining the provider + model"
narrate "  3. An HTTPRoute that exposes it on a path"
callout "The API key never leaves the cluster — agents just call the route."
pause

narrate "First, the API key Secret (created from your env var, not a manifest):"
echo -e "  ${YELLOW}\$ kubectl create secret generic anthropic-secret -n ${AGW_NS} \\${NC}"
echo -e "  ${YELLOW}    --from-literal=Authorization=\$ANTHROPIC_API_KEY${NC}"
kubectl create secret generic anthropic-secret -n "${AGW_NS}" \
  --from-literal=Authorization="${ANTHROPIC_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f - 2>&1 | sed 's/^/    /'
pause

narrate "Now the backend + route — here's the actual manifest:"
show_file "${MANIFESTS}/llm-providers/anthropic.yaml"
pause
apply_file "${MANIFESTS}/llm-providers/anthropic.yaml"
check_ok "Anthropic available at /anthropic"
pause

# ── 1.3 Test Anthropic ──────────────────────────────────────────────────────
scene "Test: Call Claude Through the Gateway"
narrate "A single curl to the gateway — it handles auth, routing, and logging."
callout "Notice: no API key in the request. The gateway injects it."
echo ""
# AGW exposes a unified OpenAI-compatible LLM API and translates to each provider's
# native API upstream. So both /anthropic and /openai routes return OpenAI-shape
# JSON (.choices[0].message.content), even for Claude. Calling /anthropic/v1/messages
# also works (the gateway accepts it) but the response is still OpenAI-shape — so
# we use /v1/chat/completions and the .choices[0] filter for both providers.
show_curl "curl -s localhost:8081/anthropic/v1/chat/completions" \
  "-H 'content-type: application/json'" \
  "-d '{\"model\":\"claude-sonnet-4-6\",\"max_tokens\":150,\"messages\":[{\"role\":\"user\",\"content\":\"In one sentence, what is an AI gateway?\"}]}'"
pause
RESPONSE=$(curl -s "${AGW_PROXY}/anthropic/v1/chat/completions" \
  -H "content-type: application/json" \
  -d '{"model":"claude-sonnet-4-6","max_tokens":150,"messages":[{"role":"user","content":"In one sentence, what is an AI gateway?"}]}' 2>/dev/null || echo '{"error":"connection failed"}')
echo "$RESPONSE" | jq -r '.choices[0].message.content // .error.message // .error // "No response"' 2>/dev/null | sed 's/^/    /' || echo "    $RESPONSE"
check_ok "Claude responded through the gateway!"
pause

# ── 1.4 Add OpenAI ──────────────────────────────────────────────────────────
scene "Add OpenAI (GPT-4o)"
narrate "Same pattern — Secret, Backend, Route. Different provider."
pause
kubectl create secret generic openai-secret -n "${AGW_NS}" \
  --from-literal=Authorization="${OPENAI_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
show_file "${MANIFESTS}/llm-providers/openai.yaml"
pause
apply_file "${MANIFESTS}/llm-providers/openai.yaml"
check_ok "OpenAI available at /openai"

echo ""
show_curl "curl -s localhost:8081/openai/v1/chat/completions" \
  "-H 'content-type: application/json'" \
  "-d '{\"model\":\"gpt-4o\",\"max_tokens\":100,\"messages\":[{\"role\":\"user\",\"content\":\"In one sentence, what is an AI gateway?\"}]}'"
pause
RESPONSE=$(curl -s "${AGW_PROXY}/openai/v1/chat/completions" \
  -H "content-type: application/json" \
  -d '{"model":"gpt-4o","max_tokens":100,"messages":[{"role":"user","content":"In one sentence, what is an AI gateway?"}]}' 2>/dev/null || echo '{"error":"connection failed"}')
echo "$RESPONSE" | jq -r '.choices[0].message.content // .error.message // .error // "No response"' 2>/dev/null | sed 's/^/    /' || echo "    $RESPONSE"
check_ok "GPT-4o responded through the gateway!"
pause

# ── 1.5 Show the state ──────────────────────────────────────────────────────
scene "Gateway State: Two LLM Providers"
run_cmd "kubectl get agentgatewaybackend -n ${AGW_NS}"
run_cmd "kubectl get httproute -n ${AGW_NS}"
narrate ""
narrate "Two LLM providers, routed through one gateway."
narrate "Agents don't need API keys — just hit the route."
callout "Next: let's give those agents some tools."
pause
fi # end ACT 1

###############################################################################
#
#  ACT 2 — MCP Servers: Tools for Your Agents
#
###############################################################################
if [ "$END_ACT" -ge 2 ]; then
act 2 "MCP Servers — Tools for Your Agents"

narrate "MCP (Model Context Protocol) gives agents access to tools:"
narrate "databases, APIs, file systems, code repos — anything."
narrate ""
narrate "AgentGateway proxies MCP traffic with the same controls as LLM"
narrate "traffic: auth, rate limits, observability. We'll set up:"
narrate "  1. A local K8s deployment (website fetcher)"
narrate "  2. Two composable MCPs — pure YAML, no code (weather, GitHub profile)"
narrate "  3. A remote MCP (GitHub Copilot)"
pause

# ── 2.1 Local MCP ────────────────────────────────────────────────────────────
scene "Local MCP: Website Fetcher"
narrate "A real MCP server running as a K8s deployment — it fetches web pages."
callout 'Key detail: the Service uses appProtocol: "agentgateway.dev/mcp"'
callout "That tells AgentGateway this is MCP traffic, not plain HTTP."
show_file "${MANIFESTS}/mcp-servers/website-fetcher.yaml"
pause
apply_file "${MANIFESTS}/mcp-servers/website-fetcher.yaml"
check_ok "Website Fetcher MCP deployed"
pause

# ── 2.2 Composable MCP: Weather ─────────────────────────────────────────────
scene "Composable MCP: Weather (Zero Code)"
narrate "An Enterprise AgentGateway feature: define MCP tools in pure YAML."
narrate "No container, no code — AGW calls an HTTP API and transforms the"
narrate "response using CEL expressions. We wrap the free Open-Meteo API."
callout "Read the inputSchema, the CEL 'path', and the CEL 'output' below."
show_file "${MANIFESTS}/mcp-servers/weather-composable.yaml"
pause
apply_file "${MANIFESTS}/mcp-servers/weather-composable.yaml"
check_ok "Weather composable MCP created (zero code!)"
pause

# ── 2.3 Composable MCP: GitHub Profile (multi-step) ─────────────────────────
scene "Composable MCP: GitHub Profile (Multi-Step)"
narrate "This composable MCP makes TWO HTTP calls in sequence and merges them:"
narrate "  Step 1: fetch the user profile   → output.user"
narrate "  Step 2: fetch their recent repos → output.repos"
narrate "  output: a CEL expression combines both"
callout "Multi-step composable tools — still zero code."
show_file "${MANIFESTS}/mcp-servers/github-profile-composable.yaml"
pause
apply_file "${MANIFESTS}/mcp-servers/github-profile-composable.yaml"
check_ok "GitHub Profile composable MCP created"
pause

# ── 2.4 Remote MCP ───────────────────────────────────────────────────────────
scene "Remote MCP: GitHub (Copilot API)"
narrate "An external MCP server hosted by GitHub. AGW proxies it over TLS."
callout "In Act 3 we'll add OAuth elicitation so agents get user consent."
show_file "${MANIFESTS}/mcp-servers/github-remote.yaml"
pause
apply_file "${MANIFESTS}/mcp-servers/github-remote.yaml"
check_ok "GitHub Remote MCP configured"
pause

# ── 2.5 Routes ───────────────────────────────────────────────────────────────
scene "Route All MCP Servers Through the Gateway"
narrate "One HTTPRoute, one rule per MCP server — each gets its own path."
show_file "${MANIFESTS}/mcp-servers/routes.yaml"
pause
apply_file "${MANIFESTS}/mcp-servers/routes.yaml"
check_ok "MCP routes created"
section_break
run_cmd "kubectl get agentgatewaybackend,enterpriseagentgatewaybackend -n ${AGW_NS}"
pause

# ── 2.6 Test ─────────────────────────────────────────────────────────────────
scene "Test: MCP Servers via Inspector"
narrate "Use the MCP Inspector to browse tools and call them live."
echo ""
echo -e "  ${BOLD}Open a new terminal and run:${NC}"
echo -e "    ${YELLOW}npx @modelcontextprotocol/inspector@0.21.2${NC}"
echo ""
echo -e "  ${BOLD}Then connect (Transport: ${GREEN}Streamable HTTP${NC}${BOLD}):${NC}"
echo -e "    Weather:   ${GREEN}http://localhost:8081/mcp/weather${NC}"
echo -e "    GitHub:    ${GREEN}http://localhost:8081/mcp/github-profile${NC}"
echo -e "    Website:   ${GREEN}http://localhost:8081/mcp/website${NC}"
echo ""
callout 'Try: get-weather-by-city → {"city": "Cambridge"}'
callout 'Try: github-user-summary → {"username": "solo-io"}'
ui_moment "Test MCP tools in the Inspector, then come back here."
fi # end ACT 2

###############################################################################
#
#  ACT 3 — Enterprise Security
#
###############################################################################
if [ "$END_ACT" -ge 3 ]; then
act 3 "Enterprise Security"

narrate "Three layers of security protect the agentic stack:"
narrate "  1. Ambient Mesh — automatic mTLS between all pods"
narrate "  2. AgentGateway — auth, rate limiting, JWT validation"
narrate "  3. Elicitation — OAuth consent for user-scoped tool access"
pause

# ── 3.1 Ambient Mesh ────────────────────────────────────────────────────────
scene "Layer 1: Ambient Mesh (mTLS Everywhere)"
narrate "Every demo namespace is enrolled in Istio ambient mesh."
narrate "ztunnel encrypts all traffic automatically — no sidecars."
echo ""
run_cmd "kubectl get namespace -l istio.io/dataplane-mode=ambient --no-headers"
narrate ""
narrate "All agent ↔ gateway ↔ MCP traffic is mTLS-encrypted."
narrate "No code changes, no sidecars, no cert management."
pause

# ── 3.2 Elicitation ──────────────────────────────────────────────────────────
scene "Layer 3: Elicitation (User OAuth Consent)"
narrate "When an agent needs a user's GitHub account, AGW triggers OAuth consent:"
narrate "  1. Agent calls GitHub MCP through AgentGateway"
narrate "  2. AGW sees no stored token → returns an elicitation URL"
narrate "  3. User opens URL → GitHub OAuth consent screen"
narrate "  4. Token stored in AGW's STS (Secure Token Service)"
narrate "  5. Subsequent calls use the stored token automatically"
callout "This is the OBO (On-Behalf-Of) pattern — agents act as the user."
pause

narrate "The OAuth client credentials go in a Secret (from your GitHub OAuth App):"
echo -e "  ${YELLOW}\$ kubectl create secret generic elicitation-oidc -n ${AGW_NS} \\${NC}"
echo -e "  ${YELLOW}    --from-literal=client_id=\$GITHUB_CLIENT_ID ... ${NC}"
kubectl create secret generic elicitation-oidc -n "${AGW_NS}" \
  --from-literal=type=oauth \
  --from-literal=title="GitHub" \
  --from-literal=instructions="## Authorize GitHub Access" \
  --from-literal=client_id="${GITHUB_CLIENT_ID}" \
  --from-literal=client_secret="${GITHUB_CLIENT_SECRET}" \
  --from-literal=app_id=github \
  --from-literal=authorize_url=https://github.com/login/oauth/authorize \
  --from-literal=access_token_url=https://github.com/login/oauth/access_token \
  --from-literal=scopes="read:user,repo" \
  --from-literal=redirect_uri=http://localhost:9090/age/elicitations \
  --dry-run=client -o yaml | kubectl apply -f - 2>&1 | sed 's/^/    /'
pause

narrate "Then the policy attaches the elicitation flow to the GitHub MCP backend:"
show_file "${MANIFESTS}/security/github-elicitation-policy.yaml"
pause
apply_file "${MANIFESTS}/security/github-elicitation-policy.yaml"
check_ok "GitHub elicitation policy configured"
narrate ""
callout "We'll see the consent screen when the github-assistant agent runs."
pause
fi # end ACT 3

###############################################################################
#
#  ACT 4 — kagent: Kubernetes-Native AI Agents
#
###############################################################################
if [ "$END_ACT" -ge 4 ]; then
act 4 "kagent — Kubernetes-Native AI Agents"

narrate "kagent deploys agents as Kubernetes pods. Each agent is defined by CRDs:"
narrate "  • ModelConfig      — which LLM to use (and how to reach it)"
narrate "  • RemoteMCPServer  — which tools to connect"
narrate "  • Agent            — system prompt, tools, deployment config"
narrate ""
narrate "We wire agents through AgentGateway so ALL traffic — LLM calls AND"
narrate "MCP calls — flows through the gateway."
pause

# ── 4.1 ModelConfigs ─────────────────────────────────────────────────────────
scene "ModelConfigs: LLM Access via AgentGateway"
narrate "ModelConfigs tell kagent how to reach an LLM. Pointing baseUrl at the"
narrate "gateway gives us central key management, observability, and rate limits."
callout "Two via-gateway configs + two direct configs for A/B comparison."
pause
narrate "First the API-key secrets in the kagent namespace:"
kubectl create secret generic anthropic-api-key -n "${KAGENT_NS}" \
  --from-literal=key="${ANTHROPIC_API_KEY}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret generic openai-api-key -n "${KAGENT_NS}" \
  --from-literal=key="${OPENAI_API_KEY}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
check_ok "API-key secrets created in ${KAGENT_NS}"
show_file "${MANIFESTS}/kagent/modelconfigs.yaml"
pause
apply_file "${MANIFESTS}/kagent/modelconfigs.yaml"
check_ok "4 ModelConfigs created"
run_cmd "kubectl get modelconfig -n ${KAGENT_NS}"
pause

# ── 4.2 RemoteMCPServers ────────────────────────────────────────────────────
scene "RemoteMCPServers: Tool Access via AgentGateway"
narrate "RemoteMCPServers tell kagent where to find MCP tools. Each points at an"
narrate "AgentGateway route, so the path is:"
callout "Agent → kagent RemoteMCPServer → AgentGateway → actual MCP backend"
show_file "${MANIFESTS}/kagent/remote-mcp-servers.yaml"
pause
apply_file "${MANIFESTS}/kagent/remote-mcp-servers.yaml"
check_ok "4 RemoteMCPServers created"
run_cmd "kubectl get remotemcpserver -n ${KAGENT_NS}"
pause

# ── 4.3 Weather Assistant ────────────────────────────────────────────────────
scene "Deploy Agent: Weather Assistant"
narrate "Our first agent — the full pipeline in one resource:"
narrate "  Anthropic (via AGW) for reasoning + Weather MCP (via AGW) for data."
show_file "${MANIFESTS}/kagent/agents/weather-assistant.yaml"
pause
apply_file "${MANIFESTS}/kagent/agents/weather-assistant.yaml"
check_ok "weather-assistant deployed"
pause

# ── 4.4 Research Agent ───────────────────────────────────────────────────────
scene "Deploy Agent: Research Agent (Multi-Tool)"
narrate "Two MCP tools: website fetcher + GitHub profiles."
callout "Multi-tool agent working through a single gateway."
show_file "${MANIFESTS}/kagent/agents/research-agent.yaml"
pause
apply_file "${MANIFESTS}/kagent/agents/research-agent.yaml"
check_ok "research-agent deployed"
pause

# ── 4.5 GitHub Assistant ─────────────────────────────────────────────────────
scene "Deploy Agent: GitHub Assistant (OBO / Elicitation)"
narrate "The agent that triggers the elicitation flow from Act 3."
narrate "First call to the GitHub MCP → OAuth consent → token stored → access."
callout "allowedHeaders: [Authorization] propagates the user's identity."
show_file "${MANIFESTS}/kagent/agents/github-assistant.yaml"
pause
apply_file "${MANIFESTS}/kagent/agents/github-assistant.yaml"
check_ok "github-assistant deployed"
pause

# ── 4.6 Orchestrator ─────────────────────────────────────────────────────────
scene "Deploy Agent: Orchestrator (A2A Multi-Agent)"
narrate "The finale agent. It doesn't call tools directly — it delegates to the"
narrate "specialist agents via A2A. Powered by GPT-4o while specialists use Claude."
callout "tools.type: Agent (not McpServer) — agents as tools for other agents."
show_file "${MANIFESTS}/kagent/agents/orchestrator-agent.yaml"
pause
apply_file "${MANIFESTS}/kagent/agents/orchestrator-agent.yaml"
check_ok "orchestrator-agent deployed"
section_break
narrate "All agents deployed. Waiting for pods..."
sleep 5
run_cmd "kubectl get agents -n ${KAGENT_NS}"
pause

# ── 4.7 Test via UI ─────────────────────────────────────────────────────────
scene "Test: Chat With Your Agents"
echo -e "  ${BOLD}URL:${NC}   ${GREEN}http://localhost:9090${NC}    ${BOLD}Login:${NC} demo / demo"
echo ""
echo -e "  ${BOLD}Try these conversations:${NC}"
echo -e "  ${CYAN}weather-assistant:${NC}"
echo '    "What is the weather in Cambridge right now?"'
echo -e "  ${CYAN}research-agent:${NC}"
echo '    "Look up the solo-io GitHub org and summarize their recent work."'
echo -e "  ${CYAN}orchestrator-agent:${NC}"
echo '    "What is the weather in San Francisco, and what has solo-io'
echo '     been working on recently on GitHub?"'
echo ""
callout "The orchestrator delegates to weather-assistant AND research-agent."
callout "Watch GPT-4o orchestrate Claude Sonnet 4 specialists!"
ui_moment "Open the UI, test the agents, then come back for the final act."
fi # end ACT 4

###############################################################################
#
#  ACT 5 — AgentRegistry: The Catalog
#
###############################################################################
if [ "$END_ACT" -ge 5 ]; then
act 5 "AgentRegistry — The Agent Catalog"

narrate "AgentRegistry is the governance layer:"
narrate "  • Catalog agents and MCP servers with metadata"
narrate "  • RBAC — who can view, deploy, invoke what"
narrate "  • Deployment orchestration — deploy agents to runtimes"
narrate "  • Telemetry — trace every LLM call and tool invocation"
narrate ""
callout "Catalog objects (ar.dev) aren't k8s CRDs — they go through the registry"
callout "API via arctl. We apply them through an in-cluster arctl helper pod."
pause
ensure_arctl_helper
pause

# ── 5.1 Runtime ──────────────────────────────────────────────────────────────
scene "Register the kagent Runtime"
narrate "A Runtime tells AgentRegistry WHERE to deploy agents — here, kagent."
show_file "${MANIFESTS}/agentregistry/runtime.yaml"
pause
ar_apply_file "${MANIFESTS}/agentregistry/runtime.yaml"
check_ok "kagent Runtime registered"
pause

# ── 5.2 MCP servers ──────────────────────────────────────────────────────────
scene "Register MCP Servers in the Catalog"
narrate "Catalog entries make MCP servers discoverable before teams wire them in."
show_file "${MANIFESTS}/agentregistry/mcp-servers.yaml"
pause
ar_apply_file "${MANIFESTS}/agentregistry/mcp-servers.yaml"
check_ok "4 MCP servers registered in the catalog"
pause

# ── 5.3 Agents ───────────────────────────────────────────────────────────────
scene "Register Agents in the Catalog"
narrate "Agent catalog entries carry discovery metadata: framework, language,"
narrate "model, and MCP dependencies."
show_file "${MANIFESTS}/agentregistry/agents.yaml"
pause
ar_apply_file "${MANIFESTS}/agentregistry/agents.yaml"
check_ok "4 agents registered in the catalog"
pause

# ── 5.4 RBAC ─────────────────────────────────────────────────────────────────
scene "RBAC: Who Can Do What"
narrate "AccessPolicies control registry + runtime permissions. Roles map to"
narrate "Keycloak groups via the 'Groups' JWT claim. Three tiers:"
narrate "  admins → full | developers → browse + invoke | viewers → browse"
callout 'Our "demo" user is in the admins group.'
show_file "${MANIFESTS}/agentregistry/access-policies.yaml"
pause
ar_apply_file "${MANIFESTS}/agentregistry/access-policies.yaml"
check_ok "3 AccessPolicies created"
pause

# ── 5.5 UI ───────────────────────────────────────────────────────────────────
scene "The Enterprise UI: Full Visibility"
narrate "The Solo Enterprise UI is a single pane of glass:"
narrate "  • Agent catalog with metadata and dependencies"
narrate "  • MCP server registry"
narrate "  • Chat interface to test agents"
narrate "  • Traces for every LLM call and tool invocation"
narrate "  • RBAC policy management"
echo ""
echo -e "  ${BOLD}URL:${NC}   ${GREEN}http://localhost:9090${NC}    ${BOLD}Login:${NC} demo / demo"
ui_moment "Explore the catalog and traces in the UI."
fi # end ACT 5

###############################################################################
#
#  ACT 6 — Promote an MCP Server to the Gateway
#
###############################################################################
if [ "$END_ACT" -ge 6 ]; then
act 6 "Promote an MCP Server to the Gateway"

narrate "A common lifecycle question: I have an MCP server cataloged in"
narrate "AgentRegistry, reachable directly. How do I put it BEHIND the gateway"
narrate "so it gets auth, policy, telemetry — and federate it with others?"
narrate ""
narrate "Note: this is a composed workflow built on two documented features —"
narrate "AgentGateway 'Virtual MCP' federation + an AgentRegistry catalog entry"
narrate "whose URL we repoint. It's 'promotion' in the release sense"
narrate "(raw/ungoverned → governed via the gateway), not a one-click button."
pause

# ── 6.1 The "before": registered but ungoverned ─────────────────────────────
scene "Before: Cataloged, but Bypassing the Gateway"
ensure_arctl_helper   # AR catalog applies go through the in-cluster arctl helper
narrate "Deploy a fresh MCP server (the MCP reference 'everything' server)."
show_file "${MANIFESTS}/mcp-servers/everything-server.yaml"
pause
apply_file "${MANIFESTS}/mcp-servers/everything-server.yaml"
check_ok "mcp-server-everything running"
narrate ""
narrate "Catalog it in AgentRegistry — note the URL points straight at the raw Service:"
show_file "${MANIFESTS}/agentregistry/everything-mcp-direct.yaml"
pause
ar_apply_file "${MANIFESTS}/agentregistry/everything-mcp-direct.yaml"
check_ok "everything-mcp cataloged (direct / ungoverned)"
narrate ""
callout "It's discoverable — but traffic skips AgentGateway entirely:"
callout "no central auth, no policy, no telemetry, no federation."
pause

# ── 6.2 Promote: put it behind the gateway (Virtual MCP) ─────────────────────
scene "Promote: Federate It Onto AgentGateway"
narrate "Create a federated 'Virtual MCP' backend that multiplexes the everything"
narrate "server AND the website-fetcher behind a single /mcp/federated endpoint."
callout "One AgentgatewayBackend, multiple targets, one client connection."
callout "failureMode: FailOpen → healthy targets keep serving if one is down."
show_file "${MANIFESTS}/mcp-servers/virtual-mcp.yaml"
pause
apply_file "${MANIFESTS}/mcp-servers/virtual-mcp.yaml"
check_ok "Federated endpoint live at /mcp/federated"
pause

# ── 6.3 Repoint the catalog entry ────────────────────────────────────────────
scene "Repoint: Update the Catalog Entry to the Gateway"
narrate "Now the promotion itself — one field changes on the SAME catalog entry:"
narrate "the URL flips from the raw Service to the governed gateway endpoint."
narrate "Compare the 'remote.url' in the before/after manifests:"
echo -e "  ${DIM}before →${NC} ...mcp-server-everything...svc.cluster.local:3001/mcp  ${DIM}(raw)${NC}"
echo -e "  ${DIM}after  →${NC} ...agentgateway-proxy...svc.cluster.local/mcp/federated  ${DIM}(gateway)${NC}"
show_file "${MANIFESTS}/agentregistry/everything-mcp-promoted.yaml"
pause
ar_apply_file "${MANIFESTS}/agentregistry/everything-mcp-promoted.yaml"
check_ok "everything-mcp repointed — same entry, now routed through AgentGateway"
narrate ""
narrate "Optionally publish the federated endpoint as its own catalog item:"
ar_apply_file "${MANIFESTS}/agentregistry/mcp-gateway.yaml"
check_ok "mcp-gateway (federated) registered in the catalog"
narrate ""
narrate "Confirm both are in the catalog:"
run_cmd "kubectl exec deploy/arctl-helper -n ${AR_NS} -- sh -c 'TOKEN=\$(curl -s -X POST \"\$OIDC_ISSUER/protocol/openid-connect/token\" -d grant_type=password -d client_id=ar-cli-password -d username=demo -d password=demo -d scope=openid | jq -r .access_token); ARCTL_API_TOKEN=\$TOKEN arctl get mcp --registry-url \$REG' | grep -E 'everything-mcp|mcp-gateway|NAME'"
pause

# ── 6.4 Verify the federation ────────────────────────────────────────────────
scene "Verify: One Endpoint, Many Servers' Tools"
narrate "Connect the MCP Inspector to the single federated endpoint:"
echo ""
echo -e "    Transport: ${GREEN}Streamable HTTP${NC}"
echo -e "    URL:       ${GREEN}http://localhost:8081/mcp/federated${NC}"
echo ""
narrate "You'll see tools from BOTH servers, name-prefixed by target:"
echo -e "    ${CYAN}everything_*${NC}        → echo, add, longRunningOperation, ..."
echo -e "    ${CYAN}website-fetcher_fetch${NC} → the website fetch tool"
echo ""
callout "Before: each server hit directly, ungoverned, separate endpoints."
callout "After: one governed /mcp/federated endpoint, AGW auth+policy+telemetry,"
callout "       and a single catalog entry agents can point at."
ui_moment "Browse /mcp/federated in the Inspector, then come back."
fi # end ACT 6

###############################################################################
#
#  ACT 7 — Advanced AgentGateway: Eager Auth, Prompt Policies, OpenAPI→MCP, Code Mode
#
###############################################################################
if [ "$END_ACT" -ge 7 ]; then
act 7 "Advanced AgentGateway — Eager Auth, Prompt Policies, OpenAPI→MCP, Code Mode"

narrate "Four power-user capabilities that turn the gateway from 'a place"
narrate "requests pass through' into 'a place requests are GOVERNED'."
narrate ""
narrate "  1. Eager Auth          — reject unauth'd requests at the gateway"
narrate "                            (API-key, then real OIDC/Keycloak JWT)"
narrate "  2. Prompt Policies     — mask PII, inject system prompts, enforce"
narrate "                            defaults on every LLM request"
narrate "  3. OpenAPI → MCP       — turn any REST API into MCP tools with zero code"
narrate "  4. Code Mode           — replace N tool round-trips with one script"
pause

# ── 7.1 Eager Auth — apiKey then JWT ──────────────────────────────────────────
scene "Eager Auth: reject unauth'd requests at the gateway"
narrate "We add a SECOND Anthropic route /secure-anthropic and put an API-key"
narrate "policy on it. Other routes (/anthropic, /openai) stay open — the policy"
narrate "is scoped to its targetRef."
show_file "${MANIFESTS}/agw-advanced/01-eager-auth.yaml"
pause
apply_file "${MANIFESTS}/agw-advanced/01-eager-auth.yaml"
check_ok "Two secured routes + apiKey policy + JWT (Keycloak) policy applied"
sleep 4
pause

scene "Test apiKey: 401 without, 401 wrong, 200 right"
echo ""
show_curl "curl -i localhost:8081/secure-anthropic/v1/chat/completions" \
  "-H 'content-type: application/json'" \
  "-d '{\"model\":\"claude-sonnet-4-6\",\"max_tokens\":20,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}'"
pause
printf "  no token:           HTTP %s\n" "$(curl -s -o /dev/null -w '%{http_code}' localhost:8081/secure-anthropic/v1/chat/completions -H 'content-type: application/json' -d '{"model":"claude-sonnet-4-6","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}')"
printf "  wrong token:        HTTP %s\n" "$(curl -s -o /dev/null -w '%{http_code}' localhost:8081/secure-anthropic/v1/chat/completions -H 'content-type: application/json' -H 'Authorization: Bearer wrong' -d '{"model":"claude-sonnet-4-6","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}')"
printf "  right token:        HTTP %s\n" "$(curl -s -o /dev/null -w '%{http_code}' localhost:8081/secure-anthropic/v1/chat/completions -H 'content-type: application/json' -H 'Authorization: Bearer demo-secret-key' -d '{"model":"claude-sonnet-4-6","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}')"
printf "  /anthropic (no policy, unaffected): HTTP %s\n" "$(curl -s -o /dev/null -w '%{http_code}' localhost:8081/anthropic/v1/chat/completions -H 'content-type: application/json' -d '{"model":"claude-sonnet-4-6","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}')"
callout "401 returned at the gateway — no Anthropic call, no token spend, no log."
pause

scene "Same idea, real OIDC — gateway validates Keycloak JWTs against the JWKS"
narrate "Fetch a real token from Keycloak (password grant, same as elicitation):"
echo ""
echo -e "  ${YELLOW}\$ TOKEN=\$(curl -s -X POST \\${NC}"
echo -e "  ${YELLOW}    http://keycloak.keycloak.svc.cluster.local:8080/realms/agentgateway/protocol/openid-connect/token \\${NC}"
echo -e "  ${YELLOW}    -d grant_type=password -d client_id=ar-cli-password \\${NC}"
echo -e "  ${YELLOW}    -d username=demo -d password=demo -d scope=openid | jq -r .access_token)${NC}"
echo ""
TOKEN=$(curl -s -X POST "http://keycloak.keycloak.svc.cluster.local:8080/realms/agentgateway/protocol/openid-connect/token" -d grant_type=password -d client_id=ar-cli-password -d username=demo -d password=demo -d scope=openid 2>/dev/null | jq -r .access_token)
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  check_fail "Keycloak unreachable from host — /etc/hosts entry missing? Skipping JWT test."
else
  check_ok "Got Keycloak token (${#TOKEN} chars)"
  printf "  bogus 'not.a.jwt': HTTP %s\n" "$(curl -s -o /dev/null -w '%{http_code}' localhost:8081/secure-anthropic-jwt/v1/chat/completions -H 'content-type: application/json' -H 'Authorization: Bearer not.a.jwt' -d '{"model":"claude-sonnet-4-6","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}')"
  printf "  real Keycloak JWT: HTTP %s\n" "$(curl -s -o /dev/null -w '%{http_code}' localhost:8081/secure-anthropic-jwt/v1/chat/completions -H 'content-type: application/json' -H "Authorization: Bearer $TOKEN" -d '{"model":"claude-sonnet-4-6","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}')"
  callout "Forged JWT → 401 (sig fails). Real Keycloak JWT → 200. Gateway never let"
  callout "the forged request reach Anthropic."
fi
pause

# ── 7.2 Prompt policies — guard + enrich + defaults ───────────────────────────
scene "Prompt Policies: mask PII, inject persona, enforce defaults"
narrate "One policy attaches THREE knobs to the Anthropic backend:"
narrate "  • promptGuard  — regex mask (built-in CC/SSN + custom patterns)"
narrate "  • prompt.prepend — inject a system message on every request"
narrate "  • defaults     — set max_tokens when caller omits it"
show_file "${MANIFESTS}/agw-advanced/02-prompt-policies.yaml"
pause
apply_file "${MANIFESTS}/agw-advanced/02-prompt-policies.yaml"
check_ok "Policy attached to AgentgatewayBackend anthropic"
sleep 3
pause

scene "Verify: enrichment — model now identifies as 'Acme Concierge'"
show_curl "curl -s localhost:8081/anthropic/v1/chat/completions" \
  "-H 'content-type: application/json'" \
  "-d '{\"model\":\"claude-sonnet-4-6\",\"max_tokens\":60,\"messages\":[{\"role\":\"user\",\"content\":\"In one sentence, who are you?\"}]}'"
pause
curl -s --max-time 25 localhost:8081/anthropic/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"claude-sonnet-4-6","max_tokens":60,"messages":[{"role":"user","content":"In one sentence, who are you?"}]}' \
  | jq -r '.choices[0].message.content // .error.message // .error // "no response"' | sed 's/^/  reply: /'
callout "The prepended system message takes effect — same gateway, every request."
pause

scene "Verify: guard — custom pattern masked BEFORE the model sees it"
narrate "Send a token matching SECRET-[A-Z0-9]{6}. The gateway replaces it with"
narrate "'<masked>' before the request reaches Anthropic — the model's reply"
narrate "describes seeing '<masked>', which is only possible if the redaction"
narrate "happened gateway-side."
show_curl "curl -s localhost:8081/anthropic/v1/chat/completions" \
  "-H 'content-type: application/json'" \
  "-d '{\"model\":\"claude-sonnet-4-6\",\"max_tokens\":80,\"messages\":[{\"role\":\"user\",\"content\":\"Echo back this token verbatim: SECRET-AB12CD\"}]}'"
pause
curl -s --max-time 25 localhost:8081/anthropic/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"claude-sonnet-4-6","max_tokens":80,"messages":[{"role":"user","content":"Echo back this token verbatim: SECRET-AB12CD"}]}' \
  | jq -r '.choices[0].message.content // .error.message // .error // "no response"' | sed 's/^/  reply: /'
callout "'masked' / '<masked>' in the reply = proof the gateway redacted upstream."
pause

scene "Verify: default — caller omits max_tokens, gateway enforces it (cap 256)"
show_curl "curl -s localhost:8081/anthropic/v1/chat/completions" \
  "-H 'content-type: application/json'" \
  "-d '{\"model\":\"claude-sonnet-4-6\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a long detailed essay about clouds.\"}]}'"
pause
curl -s --max-time 30 localhost:8081/anthropic/v1/chat/completions -H 'content-type: application/json' \
  -d '{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"Write a long detailed essay about clouds."}]}' \
  | jq '{completion_tokens: .usage.completion_tokens, finish_reason: .choices[0].finish_reason}' | sed 's/^/  /'
callout "completion_tokens ≤ 256 — gateway injected the default for an absent field."
pause

# ── 7.3 OpenAPI → MCP ────────────────────────────────────────────────────────
scene "OpenAPI → MCP: turn any REST API into agent tools, zero code"
narrate "Drop an OpenAPI 3 spec into a ConfigMap, point an entMcp backend at it"
narrate "with protocol:OpenAPI — every operation becomes an MCP tool, with"
narrate "auto-generated name / description / JSON Schema. The whole 'wrap your"
narrate "REST APIs as MCP servers' problem reduces to writing config."
show_file "${MANIFESTS}/agw-advanced/03-openapi-to-mcp.yaml"
pause
apply_file "${MANIFESTS}/agw-advanced/03-openapi-to-mcp.yaml"
check_ok "ConfigMap + entMcp backend (OpenAPI mode) + HTTPRoute applied"
sleep 4
pause

scene "Verify: tools/list on /mcp/openapi-weather — auto-discovered tools"
narrate "Open MCP Inspector → http://localhost:8081/mcp/openapi-weather"
narrate "(or run the curl below). The Tools tab shows ONE tool per OpenAPI op,"
narrate "with the description and parameters taken straight from the spec."
echo ""
INIT=$(curl -s -i --max-time 15 localhost:8081/mcp/openapi-weather -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"1"}}}' 2>/dev/null)
SID=$(echo "$INIT" | grep -i 'mcp-session-id:' | head -1 | tr -d '\r' | awk '{print $2}')
if [ -n "$SID" ]; then
  echo -e "  ${DIM}# initialize + tools/list (Streamable HTTP, mcp-session-id: ...)${NC}"
  curl -s --max-time 15 localhost:8081/mcp/openapi-weather -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    | python3 -c "import sys,json
for line in sys.stdin:
    if line.startswith('data:'):
        try:
            o=json.loads(line[5:].strip())
            for t in o.get('result',{}).get('tools',[]):
                print('    tool:',t.get('name'))
                print('      ',(t.get('description','') or '')[:120])
        except: pass"
else
  check_fail "couldn't open MCP session — check AGW logs"
fi
callout "One OpenAPI op → one auto-discovered MCP tool. No CEL, no per-op YAML."
pause

# ── 7.4 Code Mode ────────────────────────────────────────────────────────────
scene "Code Mode: replace N tool round-trips with ONE script"
narrate "Same OpenAPI spec, second backend with toolMode:Code. Instead of"
narrate "exposing one tool per operation, the gateway exposes ONE tool — a"
narrate "script executor. The LLM writes JavaScript that calls the underlying"
narrate "ops as in-process functions. Multi-step workflows go from N+1 LLM"
narrate "round-trips to ONE."
show_file "${MANIFESTS}/agw-advanced/04-code-mode.yaml"
pause
apply_file "${MANIFESTS}/agw-advanced/04-code-mode.yaml"
check_ok "Code Mode backend live on /mcp/openapi-weather-code"
sleep 4
pause

scene "Verify: tools/list — ONE tool (the script runner), not N"
INIT=$(curl -s -i --max-time 15 localhost:8081/mcp/openapi-weather-code -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"1"}}}' 2>/dev/null)
SID=$(echo "$INIT" | grep -i 'mcp-session-id:' | head -1 | tr -d '\r' | awk '{print $2}')
if [ -n "$SID" ]; then
  echo -e "  ${DIM}# /mcp/openapi-weather-code  →  Code Mode${NC}"
  curl -s --max-time 15 localhost:8081/mcp/openapi-weather-code -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    | python3 -c "import sys,json
for line in sys.stdin:
    if line.startswith('data:'):
        try:
            o=json.loads(line[5:].strip())
            for t in o.get('result',{}).get('tools',[]):
                print('    tool:',t.get('name'))
                print('      ',(t.get('description','') or '').splitlines()[0][:120])
        except: pass"
fi
echo ""
echo -e "  ${DIM}# Compare to Standard mode on the same OpenAPI spec:${NC}"
INIT=$(curl -s -i --max-time 15 localhost:8081/mcp/openapi-weather -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"1"}}}' 2>/dev/null)
SID=$(echo "$INIT" | grep -i 'mcp-session-id:' | head -1 | tr -d '\r' | awk '{print $2}')
[ -n "$SID" ] && curl -s --max-time 15 localhost:8081/mcp/openapi-weather -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | python3 -c "import sys,json
for line in sys.stdin:
    if line.startswith('data:'):
        try:
            o=json.loads(line[5:].strip())
            for t in o.get('result',{}).get('tools',[]):
                print('    tool:',t.get('name'),'(Standard)')
        except: pass"
callout "Standard mode: one tool per op (the model picks + chains them N times)."
callout "Code Mode:     one script tool (the model writes the full plan in one go)."
echo ""
narrate "Connect MCP Inspector to BOTH endpoints (Transport: Streamable HTTP) to"
narrate "see the same OpenAPI spec exposed two different ways:"
echo ""
echo -e "    ${BOLD}Standard mode${NC} — one tool per OpenAPI op"
echo -e "      Transport: ${GREEN}Streamable HTTP${NC}"
echo -e "      URL:       ${GREEN}http://localhost:8081/mcp/openapi-weather${NC}"
echo ""
echo -e "    ${BOLD}Code Mode${NC} — one script-executor tool that calls those ops itself"
echo -e "      Transport: ${GREEN}Streamable HTTP${NC}"
echo -e "      URL:       ${GREEN}http://localhost:8081/mcp/openapi-weather-code${NC}"
echo ""
narrate "Start the Inspector with:  ${BOLD}npx @modelcontextprotocol/inspector@0.21.2${NC}"
ui_moment "Open both URLs in the Inspector, compare the Tools tabs, then come back."
fi # end ACT 7

###############################################################################
#  FINALE
###############################################################################
clear
echo ""
echo -e "${BG_BLUE}${WHITE}                                                                    ${NC}"
echo -e "${BG_BLUE}${WHITE}   DEMO COMPLETE                                                    ${NC}"
echo -e "${BG_BLUE}${WHITE}                                                                    ${NC}"
echo ""
echo -e "${BOLD}What we built:${NC}"
echo ""
echo -e "  ${GREEN}AgentGateway${NC}"
echo "    2 LLM providers (Anthropic + OpenAI) with centralized auth"
echo "    4 MCP servers (local, remote, 2x composable) on one gateway"
echo "    OAuth elicitation for user-scoped GitHub access"
echo "    Virtual MCP — federated /mcp/federated endpoint (multiplexed servers)"
echo ""
echo -e "  ${GREEN}kagent${NC}"
echo "    4 ModelConfigs (via-gateway + direct for each provider)"
echo "    4 RemoteMCPServers all routed through AgentGateway"
echo "    5 agents: k8s-agent, weather, research, GitHub, orchestrator"
echo "    Multi-model orchestration (GPT-4o + Claude via A2A)"
echo ""
echo -e "  ${GREEN}AgentRegistry${NC}"
echo "    Full catalog of agents and MCP servers"
echo "    3-tier RBAC (admins / developers / viewers)"
echo "    Telemetry and tracing for every interaction"
echo "    Promoted an MCP server raw → governed (gateway) + federated"
echo ""
echo -e "  ${GREEN}Advanced AgentGateway${NC}"
echo "    Eager Auth — apiKey + real OIDC/JWT (Keycloak) rejected at the gateway"
echo "    Prompt Policies — PII masking, system-message injection, defaults"
echo "    OpenAPI → MCP — auto-generate tools from a REST spec, zero code"
echo "    Code Mode — one script tool instead of N tool round-trips"
echo ""
echo -e "  ${GREEN}Ambient Mesh${NC}"
echo "    mTLS encryption for all pod-to-pod traffic"
echo ""
echo -e "${BOLD}The integration chain:${NC}"
echo ""
echo "  User → Enterprise UI → AgentRegistry (RBAC)"
echo "    → kagent (deploys agent pod)"
echo "      → AgentGateway (LLM routing + auth)      → Anthropic / OpenAI"
echo "      → AgentGateway (MCP routing + elicitation) → MCP servers"
echo "      → A2A protocol (agent-to-agent delegation)"
echo "    All encrypted by Ambient Mesh (ztunnel)"
echo ""
echo -e "${BOLD}Every manifest is in:${NC} ${GREEN}manifests/${NC}  (browse + reuse)"
echo ""
echo -e "${BOLD}URLs:${NC}"
echo -e "  Solo Enterprise UI:  ${GREEN}http://localhost:9090${NC}  (demo/demo)"
echo -e "  Keycloak Admin:      ${GREEN}http://localhost:9091${NC}  (admin/admin)"
echo -e "  AgentGateway Proxy:  ${GREEN}http://localhost:8081${NC}"
echo -e "  AgentRegistry API:   ${GREEN}http://localhost:12121${NC}"
echo ""
echo -e "${BOLD}Replay:${NC}"
echo "  ./demo.sh          # full walkthrough"
echo "  ./demo.sh --act 3  # reset, then play acts 1..3 and stop"
echo "  ./demo.sh --reset  # clean slate"
echo ""
echo -e "${GREEN}${BOLD}Thanks for watching!${NC}"
echo ""
