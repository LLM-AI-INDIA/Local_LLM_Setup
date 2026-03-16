#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# teardown.sh
#
# Full cleanup of the LLaMA EKS deployment. Removes Kubernetes resources first
# (Helm releases, manifests), then deletes CloudFormation stacks in reverse
# dependency order.
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

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

###############################################################################
# Confirmation prompt
###############################################################################
echo ""
echo -e "${RED}==================================================${NC}"
echo -e "${RED} WARNING: This will destroy the entire deployment! ${NC}"
echo -e "${RED}==================================================${NC}"
echo ""
echo "  Region:  ${AWS_REGION}"
echo "  Account: ${AWS_ACCOUNT_ID}"
echo "  Cluster: ${CLUSTER_NAME}"
echo ""
echo "The following will be deleted:"
echo "  - All Helm releases (dcgm-exporter, monitoring, vllm-local-llm-llama,"
echo "    karpenter, aws-load-balancer-controller)"
echo "  - Karpenter NodePool/EC2NodeClass manifests"
echo "  - Kubernetes namespaces (monitoring, vllm, karpenter)"
echo "  - All 6 CloudFormation stacks"
echo ""
read -r -p "Type 'yes' to proceed: " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
    info "Teardown cancelled."
    exit 0
fi

echo ""

###############################################################################
# Helper: safe helm uninstall (ignore errors if release does not exist)
###############################################################################
safe_helm_uninstall() {
    local release="$1"
    local namespace="$2"
    info "Uninstalling Helm release: ${release} (namespace: ${namespace})"
    helm uninstall "${release}" --namespace "${namespace}" 2>/dev/null \
        && info "  Uninstalled ${release}" \
        || warn "  Release ${release} not found or already removed"
}

###############################################################################
# Helper: delete CF stack and wait
###############################################################################
delete_stack() {
    local stack_name="$1"
    info "Deleting CloudFormation stack: ${stack_name}"

    # Check if stack exists
    if ! aws cloudformation describe-stacks \
        --region "${AWS_REGION}" \
        --stack-name "${stack_name}" &>/dev/null; then
        warn "  Stack ${stack_name} does not exist, skipping."
        return 0
    fi

    aws cloudformation delete-stack \
        --region "${AWS_REGION}" \
        --stack-name "${stack_name}" \
        || { warn "Failed to initiate delete for ${stack_name}"; return 1; }

    info "  Waiting for stack ${stack_name} to be deleted ..."
    aws cloudformation wait stack-delete-complete \
        --region "${AWS_REGION}" \
        --stack-name "${stack_name}" \
        || { warn "Stack ${stack_name} deletion may have failed — check the console"; return 1; }

    info "  Stack ${stack_name} deleted."
}

###############################################################################
# 1. Uninstall monitoring Helm releases
###############################################################################
info "=== Step 1: Remove monitoring ==="
safe_helm_uninstall "dcgm-exporter" "monitoring"
safe_helm_uninstall "monitoring" "monitoring"

###############################################################################
# 2. Uninstall vLLM
###############################################################################
info "=== Step 2: Remove vLLM ==="
safe_helm_uninstall "vllm-local-llm-llama" "vllm"

###############################################################################
# 3. Delete Karpenter NodePool/EC2NodeClass manifests
###############################################################################
info "=== Step 3: Remove Karpenter NodePool configs ==="
kubectl delete -f "${REPO_ROOT}/${K8S_DIR}/karpenter/" 2>/dev/null \
    && info "  Karpenter manifests deleted" \
    || warn "  Karpenter manifests not found or already removed"

###############################################################################
# 4. Uninstall Karpenter
###############################################################################
info "=== Step 4: Remove Karpenter ==="
safe_helm_uninstall "karpenter" "karpenter"

###############################################################################
# 5. Uninstall AWS Load Balancer Controller
###############################################################################
info "=== Step 5: Remove AWS Load Balancer Controller ==="
safe_helm_uninstall "aws-load-balancer-controller" "kube-system"

###############################################################################
# 6. Delete namespaces
###############################################################################
info "=== Step 6: Delete namespaces ==="
for ns in monitoring vllm karpenter; do
    info "Deleting namespace: ${ns}"
    kubectl delete namespace "${ns}" --timeout=120s 2>/dev/null \
        && info "  Namespace ${ns} deleted" \
        || warn "  Namespace ${ns} not found or already removed"
done

###############################################################################
# 7. Delete CloudFormation stacks in reverse order
###############################################################################
info "=== Step 7: Delete CloudFormation stacks (reverse order) ==="

delete_stack "${LB_STACK_NAME}"
delete_stack "${SECRETS_STACK_NAME}"
delete_stack "${KARPENTER_STACK_NAME}"
delete_stack "${ADDONS_STACK_NAME}"
delete_stack "${EKS_STACK_NAME}"
delete_stack "${VPC_STACK_NAME}"

echo ""
info "=========================================="
info " Teardown complete."
info "=========================================="
