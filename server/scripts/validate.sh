#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# validate.sh
#
# Health-check and validation script for the LLaMA EKS deployment. Runs a
# series of checks and prints a colour-coded pass/fail summary.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../config/env.sh
source "${REPO_ROOT}/config/env.sh"

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; ((PASS++)); }
fail_check() { echo -e "  ${RED}[FAIL]${NC} $*"; ((FAIL++)); }
info() { echo -e "${YELLOW}---${NC} $*"; }

###############################################################################
# 1. CloudFormation stacks
###############################################################################
info "Checking CloudFormation stacks"

STACKS=(
    "${VPC_STACK_NAME}"
    "${EKS_STACK_NAME}"
    "${ADDONS_STACK_NAME}"
    "${KARPENTER_STACK_NAME}"
    "${SECRETS_STACK_NAME}"
    "${LB_STACK_NAME}"
)

for stack in "${STACKS[@]}"; do
    status=$(aws cloudformation describe-stacks \
        --region "${AWS_REGION}" \
        --stack-name "${stack}" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null) || status="NOT_FOUND"

    if [[ "${status}" == "CREATE_COMPLETE" || "${status}" == "UPDATE_COMPLETE" ]]; then
        pass "Stack ${stack}: ${status}"
    else
        fail_check "Stack ${stack}: ${status}"
    fi
done

###############################################################################
# 2. Nodes — at least one GPU node Ready
###############################################################################
info "Checking cluster nodes"

if kubectl get nodes -o wide 2>/dev/null | grep -q "Ready"; then
    READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || true)
    pass "Cluster has ${READY_COUNT} node(s) in Ready state"
else
    fail_check "No nodes in Ready state"
fi

GPU_NODES=$(kubectl get nodes -l "karpenter.k8s.aws/instance-gpu-count" --no-headers 2>/dev/null | wc -l || echo "0")
if [[ "${GPU_NODES}" -gt 0 ]]; then
    pass "GPU node(s) detected: ${GPU_NODES}"
else
    fail_check "No GPU nodes detected (may still be provisioning)"
fi

###############################################################################
# 3. Karpenter controller pod
###############################################################################
info "Checking Karpenter"

KARPENTER_PODS=$(kubectl get pods -n karpenter --no-headers 2>/dev/null || true)
if echo "${KARPENTER_PODS}" | grep -q "Running"; then
    pass "Karpenter controller pod is Running"
else
    fail_check "Karpenter controller pod is not Running"
fi

###############################################################################
# 4. vLLM pod
###############################################################################
info "Checking vLLM"

VLLM_PODS=$(kubectl get pods -n vllm --no-headers 2>/dev/null || true)
if echo "${VLLM_PODS}" | grep -q "Running"; then
    pass "vLLM pod is Running"
else
    fail_check "vLLM pod is not Running"
fi

###############################################################################
# 5. vLLM API health check via port-forward
###############################################################################
info "Testing vLLM API via port-forward"

VLLM_POD=$(kubectl get pods -n vllm -l app=vllm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -n "${VLLM_POD}" ]]; then
    # Start port-forward in background
    kubectl port-forward -n vllm "${VLLM_POD}" 8000:8000 &>/dev/null &
    PF_PID=$!
    sleep 3

    API_RESPONSE=$(curl -s --max-time 30 http://localhost:8000/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d '{
            "model": "meta-llama/Llama-3.1-8B-Instruct",
            "messages": [{"role": "user", "content": "Say hello in one word."}],
            "max_tokens": 10
        }' 2>/dev/null) || API_RESPONSE=""

    # Clean up port-forward
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true

    if echo "${API_RESPONSE}" | grep -q '"choices"'; then
        pass "vLLM API responded with valid chat completion"
    else
        fail_check "vLLM API did not return a valid response"
    fi
else
    fail_check "No vLLM pod found for port-forward test"
fi

###############################################################################
# 6. Spot instance check
###############################################################################
info "Checking Spot instance usage"

SPOT_NODES=$(kubectl get nodes -l "karpenter.sh/capacity-type=spot" --no-headers 2>/dev/null | wc -l || echo "0")
if [[ "${SPOT_NODES}" -gt 0 ]]; then
    pass "Spot node(s) detected: ${SPOT_NODES}"
else
    fail_check "No Spot nodes found (capacity-type label not set to spot)"
fi

###############################################################################
# 7. Prometheus targets
###############################################################################
info "Checking Prometheus"

PROM_POD=$(kubectl get pods -n monitoring -l "app.kubernetes.io/name=prometheus" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -n "${PROM_POD}" ]]; then
    kubectl port-forward -n monitoring "${PROM_POD}" 9090:9090 &>/dev/null &
    PF_PID=$!
    sleep 3

    TARGETS=$(curl -s --max-time 10 http://localhost:9090/api/v1/targets 2>/dev/null) || TARGETS=""

    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true

    if echo "${TARGETS}" | grep -q '"activeTargets"'; then
        ACTIVE_COUNT=$(echo "${TARGETS}" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',{}).get('activeTargets',[])))" 2>/dev/null || echo "?")
        pass "Prometheus has ${ACTIVE_COUNT} active target(s)"
    else
        fail_check "Could not query Prometheus targets"
    fi
else
    fail_check "Prometheus pod not found in monitoring namespace"
fi

###############################################################################
# Summary
###############################################################################
echo ""
echo "=========================================="
TOTAL=$((PASS + FAIL))
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC} out of ${TOTAL} checks"
echo "=========================================="

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
