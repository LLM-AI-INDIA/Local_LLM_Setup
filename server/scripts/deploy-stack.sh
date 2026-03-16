#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# deploy-stack.sh
#
# Deploy all 6 CloudFormation stacks in dependency order, waiting for each to
# complete before proceeding. After the EKS cluster stack, kubeconfig is
# updated automatically.
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

TEMPLATE_DIR="${REPO_ROOT}/${CF_TEMPLATE_DIR}"

###############################################################################
# deploy_stack <stack-name> <template-file> [capabilities]
#
# Deploys a single CloudFormation stack and waits for completion.
###############################################################################
deploy_stack() {
    local stack_name="$1"
    local template_file="$2"
    local capabilities="${3:-}"
    local extra_args=()
    if [[ $# -gt 3 ]]; then
        extra_args=("${@:4}")
    fi

    local template_path="${TEMPLATE_DIR}/${template_file}"
    if [[ ! -f "${template_path}" ]]; then
        fail "Template not found: ${template_path}"
    fi

    info "Deploying stack: ${stack_name} (template: ${template_file})"

    local caps_arg=()
    if [[ -n "${capabilities}" ]]; then
        caps_arg=(--capabilities "${capabilities}")
    fi

    aws cloudformation deploy \
        --region "${AWS_REGION}" \
        --stack-name "${stack_name}" \
        --template-file "${template_path}" \
        "${caps_arg[@]}" \
        ${extra_args[@]+"${extra_args[@]}"} \
        --no-fail-on-empty-changeset \
        || fail "Failed to deploy stack ${stack_name}"

    info "Waiting for stack ${stack_name} to reach a stable state ..."
    aws cloudformation wait stack-create-complete \
        --region "${AWS_REGION}" \
        --stack-name "${stack_name}" 2>/dev/null \
    || aws cloudformation wait stack-update-complete \
        --region "${AWS_REGION}" \
        --stack-name "${stack_name}" 2>/dev/null \
    || true  # deploy --no-fail-on-empty-changeset may mean no update

    # Verify the stack reached a successful state
    local status
    status=$(aws cloudformation describe-stacks \
        --region "${AWS_REGION}" \
        --stack-name "${stack_name}" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null) || true

    case "${status}" in
        CREATE_COMPLETE|UPDATE_COMPLETE)
            info "Stack ${stack_name} is ${status}"
            ;;
        *)
            fail "Stack ${stack_name} ended in unexpected state: ${status}"
            ;;
    esac
}

###############################################################################
# Main — deploy stacks in order
###############################################################################
info "=========================================="
info " LLaMA EKS — CloudFormation Deployment"
info "=========================================="
info "Region:  ${AWS_REGION}"
info "Account: ${AWS_ACCOUNT_ID}"
info "Cluster: ${CLUSTER_NAME}"
echo ""

# 1. VPC & networking
deploy_stack "${VPC_STACK_NAME}" "01-vpc-networking.yaml"

# 2. EKS cluster (requires IAM capabilities for service roles)
deploy_stack "${EKS_STACK_NAME}" "02-eks-cluster.yaml" "CAPABILITY_NAMED_IAM"

# Update kubeconfig so subsequent kubectl/helm commands work
info "Updating kubeconfig for cluster ${CLUSTER_NAME} ..."
aws eks update-kubeconfig \
    --region "${AWS_REGION}" \
    --name "${CLUSTER_NAME}" \
    --alias "${CLUSTER_NAME}" \
    || fail "Failed to update kubeconfig"

# 3. EKS add-ons (CoreDNS, kube-proxy, VPC-CNI, EBS CSI)
deploy_stack "${ADDONS_STACK_NAME}" "03-eks-addons.yaml"

# Fetch OIDC values from EKS cluster stack for stacks 4, 5, 6
OIDC_ARN=$(aws cloudformation describe-stacks \
    --region "${AWS_REGION}" --stack-name "${EKS_STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='OIDCProviderArn'].OutputValue" --output text)
OIDC_URL=$(aws cloudformation describe-stacks \
    --region "${AWS_REGION}" --stack-name "${EKS_STACK_NAME}" \
    --query "Stacks[0].Outputs[?OutputKey=='OIDCProviderUrl'].OutputValue" --output text)
info "OIDC Provider ARN: ${OIDC_ARN}"
info "OIDC Provider URL: ${OIDC_URL}"

# 4. Karpenter IAM roles
deploy_stack "${KARPENTER_STACK_NAME}" "04-karpenter-iam.yaml" "CAPABILITY_NAMED_IAM" \
    --parameter-overrides "OIDCProviderArn=${OIDC_ARN}" "OIDCProviderUrl=${OIDC_URL}"

# 5. Secrets Manager & S3 bucket
deploy_stack "${SECRETS_STACK_NAME}" "05-secrets-and-s3.yaml" "CAPABILITY_NAMED_IAM" \
    --parameter-overrides "OIDCProviderArn=${OIDC_ARN}" "OIDCProviderUrl=${OIDC_URL}"

# 6. AWS Load Balancer Controller IAM role
deploy_stack "${LB_STACK_NAME}" "06-lb-controller-iam.yaml" "CAPABILITY_NAMED_IAM" \
    --parameter-overrides "OIDCProviderArn=${OIDC_ARN}" "OIDCProviderUrl=${OIDC_URL}"

echo ""
info "=========================================="
info " All CloudFormation stacks deployed."
info "=========================================="
