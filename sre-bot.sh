#!/usr/bin/env bash
#
# sre-bot.sh — a stand-in for a Slack SRE bot calling kagent over A2A.
#
# Plays the "user-facing integration" role: mints a Keycloak token as a human
# user, then sends Slack-style questions to kagent agents through the controller's
# OIDC-protected A2A endpoint (the same path a Slack bolt app would use). Every
# call produces a full trace (agent -> LLM -> subagents -> MCP tools) in the Solo
# Enterprise UI Tracing tab.
#
# Each request carries a W3C `traceparent` header with a fresh trace id, and the
# id is printed, so you can test whether an upstream caller's trace context is
# honored (search the id in the Tracing tab / ClickHouse).
#
# Usage:
#   ./sre-bot.sh                 # one round through the prompt list
#   ./sre-bot.sh --loop 30       # keep going, ~30s between calls (Ctrl-C to stop)
#   ./sre-bot.sh --count 5       # exactly 5 calls
#   ./sre-bot.sh --agent k8s-agent "how many pods in kagent?"   # one ad-hoc call
#
# Needs: ./port-forward.sh running, plus the controller forward:
#   kubectl -n kagent port-forward svc/kagent-controller 8083:8083
# and the /etc/hosts entry for keycloak.keycloak.svc.cluster.local (see DEMO.md).

set -euo pipefail

KC="${KC:-http://keycloak.keycloak.svc.cluster.local:8080}"   # issuer must match the controller's
REALM="${REALM:-agentgateway}"
CLIENT="${CLIENT:-kagent-ui}"
USER_="${SRE_USER:-demo}"
PASS_="${SRE_PASS:-demo}"
CTRL="${CTRL:-http://localhost:8083}"
NS="${KAGENT_NS:-kagent}"
CHANNEL="${SLACK_CHANNEL:-#sre-oncall}"

LOOP=""; COUNT=""; ONE_AGENT=""; ONE_PROMPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --loop)  LOOP="${2:-30}"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    --agent) ONE_AGENT="$2"; ONE_PROMPT="${3:-}"; shift 3 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

BOLD='\033[1m'; DIM='\033[2m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

# agent|prompt — what an SRE would actually type into Slack
PROMPTS=(
  "k8s-agent|Which pods in the kagent namespace have restarted, and how many times?"
  "orchestrator-agent|Weather in London right now, and who is GitHub user octocat? One line each."
  "k8s-agent|List the deployments in agentgateway-system and whether each is fully available."
  "weather-assistant|Is it raining in Pleasanton, CA right now?"
  "k8s-agent|Summarize the health of the kagent-controller deployment in kagent in two sentences."
  "research-agent|Who is the GitHub user solo-io? One sentence."
  "orchestrator-agent|Give me the weather in Tokyo and the GitHub profile of torvalds, one line each."
  "k8s-agent|How many nodes are in this cluster and are they all Ready?"
)

token() {
  curl -s -X POST "$KC/realms/$REALM/protocol/openid-connect/token" \
    -d grant_type=password -d client_id="$CLIENT" -d username="$USER_" -d password="$PASS_" -d scope=openid \
    | jq -r .access_token
}

rand_hex() { head -c "$1" /dev/urandom | xxd -p | tr -d '\n'; }

ask() {
  local agent=$1 prompt=$2
  local tok trace_id span_id msg_id t0 t1 code body text
  tok=$(token)
  [ -n "$tok" ] && [ "$tok" != "null" ] || { echo -e "${RED}could not get a token from $KC${NC}"; return 1; }
  trace_id=$(rand_hex 16); span_id=$(rand_hex 8); msg_id="srebot-$(date +%s)-$RANDOM"
  echo -e "${CYAN}[${CHANNEL}] @${USER_}:${NC} ${BOLD}${prompt}${NC}"
  echo -e "  ${DIM}→ ${agent}  traceparent=00-${trace_id}-${span_id}-01  messageId=${msg_id}${NC}"
  t0=$(date +%s)
  body=$(curl -s -m 180 -w '\n%{http_code}' -X POST "$CTRL/api/a2a/$NS/$agent/" \
    -H "Authorization: Bearer $tok" -H 'content-type: application/json' \
    -H "traceparent: 00-${trace_id}-${span_id}-01" \
    -H "X-Slack-Channel: ${CHANNEL}" -H "X-Slack-User: ${USER_}" \
    -d "$(jq -cn --arg id "$msg_id" --arg text "$prompt" \
      '{jsonrpc:"2.0",id:$id,method:"message/send",params:{message:{role:"user",kind:"message",messageId:$id,parts:[{kind:"text",text:$text}]}}}')")
  t1=$(date +%s)
  code=$(printf '%s' "$body" | tail -n1); body=$(printf '%s' "$body" | sed '$d')
  if [ "$code" != "200" ]; then
    echo -e "  ${RED}HTTP $code${NC} $(printf '%s' "$body" | head -c 300)"; return 1
  fi
  text=$(printf '%s' "$body" | python3 -c '
import sys,json
o=json.load(sys.stdin); r=o.get("result",{})
parts=[p.get("text","") for a in r.get("artifacts",[]) for p in a.get("parts",[]) if p.get("kind")=="text"]
if not parts:
    parts=[p.get("text","") for m in r.get("history",[]) if m.get("role")=="agent" for p in m.get("parts",[]) if p.get("kind")=="text"]
print((parts[-1] if parts else json.dumps(o)[:400]).replace("\n"," ")[:500])')
  echo -e "  ${GREEN}${agent} (${DIM}$((t1-t0))s${NC}${GREEN}):${NC} ${text}"
  echo
}

if [ -n "$ONE_AGENT" ]; then
  ask "$ONE_AGENT" "${ONE_PROMPT:-Say OK.}"; exit $?
fi

n=0
while :; do
  for entry in "${PROMPTS[@]}"; do
    ask "${entry%%|*}" "${entry#*|}" || true
    n=$((n+1))
    [ -n "$COUNT" ] && [ "$n" -ge "$COUNT" ] && exit 0
    [ -n "$LOOP" ] && sleep "$LOOP"
  done
  [ -z "$LOOP" ] && break
done
