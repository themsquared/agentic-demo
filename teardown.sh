#!/usr/bin/env bash
#
# Solo Agentic Demo — Teardown
#
# Deletes the k3d cluster and cleans up everything.
#

set -euo pipefail

CLUSTER_NAME="ai-demo"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${RED}Deleting k3d cluster '${CLUSTER_NAME}'...${NC}"
k3d cluster delete "${CLUSTER_NAME}" 2>/dev/null || true

echo -e "${GREEN}Done. Cluster '${CLUSTER_NAME}' has been removed.${NC}"
