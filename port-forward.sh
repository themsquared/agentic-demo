#!/usr/bin/env bash
#
# Solo Agentic Demo — Port Forwards
#
# Starts port-forwards for the demo environment.
# Run this after setup.sh completes. Re-run if forwards die.
#
# THE demo — one tab:
#   http://localhost:9090  — Solo Enterprise UI: login, agent chat, AgentRegistry
#                            catalog, AGW config, Tracing, AND the GitHub OAuth
#                            elicitation callback (:9090/age/elicitations).
#
# Operator / debug only (not shown to the audience):
#   http://localhost:8080  — Keycloak (OIDC issuer + admin console, admin/admin)
#   http://localhost:8081  — AgentGateway proxy (LLM + MCP routes)
#   http://localhost:12121 — AgentRegistry API (for the arctl CLI)
#
# Usage:
#   ./port-forward.sh          # start all forwards in background
#   ./port-forward.sh --stop   # kill all forwards
#

set -euo pipefail

AGW_NS="agentgateway-system"
KAGENT_NS="kagent"
AR_NS="agentregistry-system"
KC_NS="keycloak"

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

PID_FILE="/tmp/agentic-demo-pf.pids"

stop_forwards() {
  if [ -f "$PID_FILE" ]; then
    echo -e "${YELLOW}Stopping existing port-forwards...${NC}"
    while read -r pid; do
      kill "$pid" 2>/dev/null || true
    done < "$PID_FILE"
    rm -f "$PID_FILE"
    echo -e "${GREEN}All port-forwards stopped.${NC}"
  else
    echo "No port-forwards running (no PID file found)."
  fi
}

if [ "${1:-}" = "--stop" ]; then
  stop_forwards
  exit 0
fi

# Kill any existing forwards first
stop_forwards 2>/dev/null

echo -e "${BOLD}Starting port-forwards for Solo Agentic Demo...${NC}\n"

> "$PID_FILE"

start_forward() {
  local label=$1 ns=$2 svc=$3 local_port=$4 remote_port=$5
  echo -en "  ${CYAN}${label}${NC} → localhost:${local_port} ... "
  kubectl port-forward "svc/${svc}" -n "$ns" "${local_port}:${remote_port}" >/dev/null 2>&1 &
  local pid=$!
  echo "$pid" >> "$PID_FILE"
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    echo -e "${GREEN}OK${NC} (PID ${pid})"
  else
    echo -e "${RED}FAILED${NC} — check that the service exists: kubectl get svc ${svc} -n ${ns}"
  fi
}

# ── THE demo surface — one tab ────────────────────────────────────────────────
# Solo Enterprise UI on 9090. This is the ONLY URL a prospect ever touches:
# login, chat with agents, browse the catalog, AND the GitHub OAuth elicitation
# callback all happen here (redirect_uri / CALLBACK_URL = :9090/age/elicitations).
start_forward "Solo Enterprise UI (the demo)"      "$KAGENT_NS" "solo-enterprise-ui"             9090 80
# Keycloak on 8080: the OIDC issuer. The browser is redirected here for login
# (transparent SSO), so it must be reachable at the issuer host:port — hence the
# /etc/hosts entry below. Not a place anyone navigates to manually.
start_forward "Keycloak (OIDC issuer)"             "$KC_NS"     "keycloak"                        8080 8080

# ── Operator / debugging only (NOT part of the prospect demo) ─────────────────
start_forward "AgentGateway proxy (debug)"         "$AGW_NS"    "agentgateway-proxy"              8081 80
start_forward "AgentRegistry API (arctl)"          "$AR_NS"     "agentregistry-enterprise-server" 12121 12121

echo ""
echo -e "${BOLD}Ready.${NC}"
echo ""
echo -e "  ${BOLD}${GREEN}▶ THE DEMO — one tab:${NC} http://localhost:9090   (login: demo / demo)"
echo -e "    Agents · AgentRegistry catalog · AgentGateway config · Tracing — all here."
echo -e "    GitHub OAuth consent (elicitation) also completes here. No other UI needed."
echo ""
echo -e "  ${DIM}operator/debug only: Keycloak http://localhost:8080 (admin/admin) ·"
echo -e "  AGW proxy :8081 · AgentRegistry API :12121${NC}"
echo ""
echo -e "${BOLD}${YELLOW}ONE-TIME host entry (browser SSO)${NC} — so the OIDC issuer resolves:"
echo -e "  ${YELLOW}echo \"127.0.0.1 keycloak.keycloak.svc.cluster.local\" | sudo tee -a /etc/hosts${NC}"
echo ""
echo -e "${YELLOW}To stop: ./port-forward.sh --stop${NC}"
echo -e "${YELLOW}PIDs saved to: ${PID_FILE}${NC}"
