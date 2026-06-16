#!/usr/bin/env bash
#
# kagent Demo — Tools, Tool Servers, and Promotion from AgentRegistry
#
# A tight, focused walkthrough of the kagent runtime, separate from the main
# demo.sh. Three acts:
#
#   Act 1 — Add a TOOL SERVER       (register a RemoteMCPServer; kagent discovers its tools)
#   Act 2 — Add TOOLS to an AGENT   (build a declarative agent, then grow it with a 2nd tool server)
#   Act 3 — PROMOTE from AgentRegistry → kagent
#                                   (a packaged BYO-image agent: catalog Agent + Deployment → running agent)
#
# Acts 1-2 are declarative (system prompt + tool refs, no images). Act 3 is the
# build-and-ship lifecycle: a container image (built + k3d-imported by setup.sh)
# is registered in the AgentRegistry catalog and deployed onto the kagent runtime,
# which AgentRegistry materializes as a native kagent.dev/Agent.
#
# Every resource shown is the SAME file under manifests/ that gets applied.
#
# Prerequisite: ./setup.sh has been run and ./port-forward.sh is active.
#   Act 3 additionally needs the packaged image in-cluster (setup.sh Step 11.5).
#
# Usage:
#   ./kagent-demo.sh            # full interactive demo
#   ./kagent-demo.sh --reset    # remove just this demo's resources
#   ./kagent-demo.sh --act 3    # jump to an act (1-3)
#
# Controls: Press Enter to advance.  Ctrl-C to exit.
#

set -euo pipefail

KAGENT_NS="kagent"
AR_NS="agentregistry-system"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="${SCRIPT_DIR}/manifests"
KDEMO="${MANIFESTS}/kagent-demo"
WEATHERWISE_IMAGE="solo-demo/weatherwise:latest"

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; RED='\033[0;31m'; MAGENTA='\033[0;35m'; WHITE='\033[1;37m'
NC='\033[0m'; BG_BLUE='\033[44m'

STEP_NUM=0
pause()    { echo ""; echo -en "  ${DIM}[ Press Enter to continue ]${NC}"; read -r; echo ""; }
act()      { STEP_NUM=0; clear 2>/dev/null || true; echo ""; echo -e "${BG_BLUE}${WHITE}                                                                    ${NC}";
             echo -e "${BG_BLUE}${WHITE}   ACT $1: ${*:2}${NC}"; echo -e "${BG_BLUE}${WHITE}                                                                    ${NC}"; echo ""; pause; }
scene()    { STEP_NUM=$((STEP_NUM+1)); echo ""; echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}";
             echo -e "${BOLD}${CYAN}  ${STEP_NUM}. $*${NC}"; echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo ""; }
narrate()  { echo -e "  ${DIM}$*${NC}"; }
callout()  { echo -e "  ${YELLOW}▸ $*${NC}"; }
check_ok() { echo -e "  ${GREEN}✓ $*${NC}"; }
check_fail(){ echo -e "  ${RED}✗ $*${NC}"; }

show_file() {
  local f=$1; local rel="manifests/${f#"${MANIFESTS}"/}"
  echo -e "  ${BOLD}📄 ${rel}${NC}"
  echo -e "  ${MAGENTA}┌────────────────────────────────────────────────────────${NC}"
  while IFS= read -r line; do echo -e "  ${MAGENTA}│${NC} ${line}"; done < "$f"
  echo -e "  ${MAGENTA}└────────────────────────────────────────────────────────${NC}"
}
apply_file() { local f=$1; local rel="manifests/${f#"${MANIFESTS}"/}"
  echo -e "  ${YELLOW}\$ kubectl apply -f ${rel}${NC}"; kubectl apply -f "$f" 2>&1 | sed 's/^/    /'; }
run_cmd()    { echo -e "  ${YELLOW}\$ $*${NC}"; eval "$@" 2>&1 | sed 's/^/    /'; }
ui_moment()  { echo ""; echo -e "  ${BG_BLUE}${WHITE}  SWITCH TO BROWSER  ${NC}"; echo -e "  ${BOLD}$*${NC}"; pause; }

ensure_arctl_helper() {
  kubectl get deploy arctl-helper -n "${AR_NS}" >/dev/null 2>&1 || \
    kubectl apply -f "${MANIFESTS}/agentregistry/arctl-helper.yaml" >/dev/null 2>&1
  kubectl rollout status deploy/arctl-helper -n "${AR_NS}" --timeout=180s >/dev/null 2>&1 \
    && check_ok "arctl helper ready" || check_fail "arctl helper not ready"
}
ar_apply_file() { local f=$1; local rel="manifests/${f#"${MANIFESTS}"/}"
  echo -e "  ${YELLOW}\$ arctl apply -f ${rel}   ${DIM}(via in-cluster helper)${NC}"
  kubectl exec -i deploy/arctl-helper -n "${AR_NS}" -- arctl-apply < "$f" 2>&1 | sed 's/^/    /'; }

# Wait for a kagent agent's Deployment to be ready. Waits on both the rollout AND
# the pod's Ready condition — `rollout status` can return a beat before the new
# pod passes its readiness probe, and an A2A call in that gap gets a connection
# reset. The extra pod-Ready wait closes that race for unattended runs.
wait_agent() {
  local name=$1 timeout=${2:-150}
  narrate "waiting for agent '${name}' to be ready (≤${timeout}s)..."
  kubectl rollout status "deploy/${name}" -n "${KAGENT_NS}" --timeout="${timeout}s" 2>&1 | tail -1 | sed 's/^/    /' || true
  kubectl wait --for=condition=Ready pod -l "kagent=${name}" -n "${KAGENT_NS}" --timeout=60s >/dev/null 2>&1 || true
}

# Chat with a DECLARATIVE agent over A2A from the in-cluster helper (works because
# declarative agents have no waypoint, so cross-namespace plaintext is allowed).
a2a_via_helper() {
  local agent=$1 prompt=$2
  echo -e "  ${YELLOW}▸ ${agent} ⇐ \"${prompt}\"${NC}"
  kubectl exec deploy/arctl-helper -n "${AR_NS}" -- sh -c \
    "curl -s -m 120 http://${agent}.${KAGENT_NS}.svc.cluster.local:8080/ -H 'content-type: application/json' \
     -d '{\"jsonrpc\":\"2.0\",\"id\":\"d\",\"method\":\"message/send\",\"params\":{\"message\":{\"role\":\"user\",\"kind\":\"message\",\"messageId\":\"dm\",\"parts\":[{\"kind\":\"text\",\"text\":\"${prompt}\"}]}}}'" \
    2>&1 | python3 -c "import sys,re;raw=sys.stdin.read();t=re.findall(r'\"text\":\"((?:[^\"\\\\]|\\\\.)*)\"',raw);print('    '+(t[-1][:400] if t else '(no text) '+raw[:200]))"
}

# Chat with a BYO agent via its own pod localhost (bypasses the per-agent waypoint
# — proves the running image answers using the gateway LLM + MCP tool). The
# in-browser UI is the real experience; this is the CLI confirmation.
a2a_via_pod() {
  local label=$1 prompt=$2
  local pod
  pod=$(kubectl get pods -n "${KAGENT_NS}" -o name | grep -E "${label}-[0-9a-f]" | head -1 | cut -d/ -f2)
  [ -z "$pod" ] && { check_fail "no pod for ${label}"; return; }
  echo -e "  ${YELLOW}▸ ${label} ⇐ \"${prompt}\"  ${DIM}(in-pod)${NC}"
  kubectl exec "$pod" -n "${KAGENT_NS}" -- python3 -c "
import urllib.request,json,re
b=json.dumps({'jsonrpc':'2.0','id':'d','method':'message/send','params':{'message':{'role':'user','kind':'message','messageId':'dm','parts':[{'kind':'text','text':'''${prompt}'''}]}}}).encode()
try:
    r=urllib.request.urlopen(urllib.request.Request('http://localhost:8080/',data=b,headers={'content-type':'application/json'}),timeout=115)
    o=r.read().decode();t=re.findall(r'\"text\":\"((?:[^\"\\\\]|\\\\.)*)\"',o)
    print('    '+(t[-1][:400] if t else '(no text) '+o[:200]))
except Exception as e:
    print('    ERR:',repr(e)[:200])
" 2>&1
}

###############################################################################
# Reset — remove only this demo's resources
###############################################################################
reset_demo() {
  echo -e "${YELLOW}Resetting kagent-demo resources...${NC}"
  kubectl delete agent helpdesk -n "${KAGENT_NS}" 2>/dev/null || true
  kubectl delete remotemcpserver kdemo-weather kdemo-github -n "${KAGENT_NS}" 2>/dev/null || true
  if kubectl get deploy arctl-helper -n "${AR_NS}" >/dev/null 2>&1; then
    kubectl exec deploy/arctl-helper -n "${AR_NS}" -- arctl-delete deployment weatherwise-kagent 2>/dev/null || true
    kubectl exec deploy/arctl-helper -n "${AR_NS}" -- arctl-delete agent weatherwise 2>/dev/null || true
  fi
  # AR deletes the materialized kagent Agent + waypoint when the Deployment goes.
  echo -e "${GREEN}Done. (Infrastructure, main-demo agents, and the imported image are untouched.)${NC}"
}

###############################################################################
# Acts
###############################################################################
act1() {
  act 1 "Add a Tool Server"
  scene "What a tool server is"
  narrate "A RemoteMCPServer registers an MCP endpoint with kagent. kagent connects,"
  narrate "discovers the tools it exposes, and makes them available to agents. The URL"
  narrate "points at an AgentGateway route — so every tool call is governed by the gateway."
  pause

  scene "Register the weather tool server"
  show_file "${KDEMO}/01-tool-server-weather.yaml"
  pause
  apply_file "${KDEMO}/01-tool-server-weather.yaml"
  narrate "giving kagent a moment to connect and discover tools..."
  sleep 6
  pause

  scene "kagent discovered its tools"
  run_cmd "kubectl get remotemcpserver kdemo-weather -n ${KAGENT_NS}"
  run_cmd "kubectl get remotemcpserver kdemo-weather -n ${KAGENT_NS} -o jsonpath='{.status.discoveredTools[*].name}{\"\\n\"}'"
  callout "That's a tool server added. Nothing uses it yet — agents reference it next."
  pause
}

act2() {
  act 2 "Add Tools to an Agent"
  scene "Build a declarative agent that uses the tool server"
  narrate "A declarative agent is a system prompt + a model + a list of tools — no image,"
  narrate "no code. The 'tools' block is where you ADD TOOLS: each entry points at a tool"
  narrate "server and the specific tool names the agent may call."
  pause
  show_file "${KDEMO}/02-helpdesk-weather.yaml"
  pause
  apply_file "${KDEMO}/02-helpdesk-weather.yaml"
  wait_agent helpdesk 150
  pause

  scene "Chat: it can do weather"
  a2a_via_helper helpdesk "What is the weather in Tokyo right now?"
  callout "LLM and tool call both flowed through the AgentGateway."
  pause

  scene "Grow the agent: add a SECOND tool server"
  narrate "Same pattern — register another tool server (GitHub profiles)..."
  show_file "${KDEMO}/03-tool-server-github.yaml"
  pause
  apply_file "${KDEMO}/03-tool-server-github.yaml"
  sleep 5

  scene "...then add those tools to the agent"
  narrate "Re-apply helpdesk with a second tools entry referencing the new server."
  show_file "${KDEMO}/04-helpdesk-add-github.yaml"
  pause
  apply_file "${KDEMO}/04-helpdesk-add-github.yaml"
  wait_agent helpdesk 150
  pause

  scene "Chat: now it can also look up GitHub users"
  a2a_via_helper helpdesk "Who is the GitHub user solo-io? One sentence."
  callout "Adding capability = register a tool server, then reference it from the agent."
  ui_moment "Open http://localhost:9090 → Agents → helpdesk and chat with it live."
}

act3() {
  act 3 "Promote an Agent from AgentRegistry → kagent"
  scene "Declarative vs packaged agents"
  narrate "Acts 1-2 built a DECLARATIVE agent (prompt + tools). Some agents ship as"
  narrate "CONTAINERS instead — custom code, packaged as an image. AgentRegistry is where"
  narrate "those are cataloged, governed, and PROMOTED onto a runtime like kagent."
  narrate ""
  narrate "The image (agents-src/weatherwise) was built + loaded into the cluster by setup.sh."
  if ! docker image inspect "${WEATHERWISE_IMAGE}" >/dev/null 2>&1 && \
     ! kubectl get agent weatherwise -n "${KAGENT_NS}" >/dev/null 2>&1; then
    check_fail "Packaged image not found. Re-run setup.sh (Step 11.5) with docker available."
  fi
  ensure_arctl_helper
  pause

  scene "Register the agent in the catalog (carries source.image)"
  narrate "This makes it browsable/governable in AgentRegistry. It does NOT run yet."
  show_file "${MANIFESTS}/agentregistry/weatherwise-agent.yaml"
  pause
  ar_apply_file "${MANIFESTS}/agentregistry/weatherwise-agent.yaml"
  pause

  scene "Promote it: deploy the catalog Agent onto the kagent runtime"
  narrate "A Deployment binds the catalog Agent (targetRef) to the kagent runtime"
  narrate "(runtimeRef). AgentRegistry's Kagent adapter translates it into a native"
  narrate "kagent.dev/Agent running the image — one declarative record, a running agent."
  show_file "${MANIFESTS}/agentregistry/deployments.yaml"
  pause
  ar_apply_file "${MANIFESTS}/agentregistry/deployments.yaml"
  pause

  scene "AgentRegistry materialized a native kagent Agent"
  narrate "watch the BYO agent appear and become ready..."
  sleep 6
  run_cmd "kubectl get agent weatherwise -n ${KAGENT_NS}"
  wait_agent weatherwise 150
  run_cmd "kubectl get agent weatherwise -n ${KAGENT_NS} -o jsonpath='{.spec.type}  ready={.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}'"
  pause

  scene "Chat: the promoted agent answers via the gateway + its MCP tool"
  a2a_via_pod weatherwise "What is the weather in Paris right now?"
  callout "Built as an image → cataloged in AgentRegistry → promoted to kagent → running."
  ui_moment "Open http://localhost:9090 → Agents → weatherwise and chat with it live."
}

###############################################################################
# Entry
###############################################################################
case "${1:-}" in
  --reset) reset_demo; exit 0 ;;
  --act)
    case "${2:-}" in
      1) act1 ;; 2) act2 ;; 3) act3 ;;
      *) echo "usage: $0 --act {1|2|3}"; exit 1 ;;
    esac
    echo ""; check_ok "Act ${2} complete."; exit 0 ;;
  "") : ;;
  *) echo "usage: $0 [--reset | --act N]"; exit 1 ;;
esac

clear 2>/dev/null || true
echo -e "${BG_BLUE}${WHITE}                                                          ${NC}"
echo -e "${BG_BLUE}${WHITE}   kagent Demo — Tools, Tool Servers, Promotion           ${NC}"
echo -e "${BG_BLUE}${WHITE}                                                          ${NC}"
echo ""
narrate "Three acts: add a tool server → add tools to an agent → promote a packaged"
narrate "agent from AgentRegistry onto the kagent runtime."
narrate "Prereqs: ./setup.sh done, ./port-forward.sh active. Have http://localhost:9090 open."
pause
act1
act2
act3
echo ""
echo -e "${GREEN}${BOLD}kagent demo complete.${NC}"
narrate "Reset just this demo's resources with:  ./kagent-demo.sh --reset"
