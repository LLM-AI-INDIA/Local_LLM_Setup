#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# deploy-k8s.sh
#
# Deploy all Kubernetes-level resources (Karpenter, vLLM, monitoring, LB
# controller) after CloudFormation stacks are in place.
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
# Helper: get a CloudFormation stack output value
###############################################################################
cf_output() {
    local stack="$1" key="$2"
    aws cloudformation describe-stacks \
        --region "${AWS_REGION}" \
        --stack-name "${stack}" \
        --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
        --output text
}

###############################################################################
# 1. Install Karpenter via Helm (OCI registry)
###############################################################################
info "=== Step 1: Install Karpenter ==="

KARPENTER_CONTROLLER_ROLE_ARN=$(cf_output "${KARPENTER_STACK_NAME}" "KarpenterControllerRoleArn")
if [[ -z "${KARPENTER_CONTROLLER_ROLE_ARN}" || "${KARPENTER_CONTROLLER_ROLE_ARN}" == "None" ]]; then
    fail "Could not retrieve KarpenterControllerRoleArn from stack ${KARPENTER_STACK_NAME}"
fi
info "Karpenter controller role ARN: ${KARPENTER_CONTROLLER_ROLE_ARN}"

kubectl create namespace karpenter 2>/dev/null || true

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
    --namespace karpenter \
    --version "${KARPENTER_VERSION}" \
    --set "settings.clusterName=${CLUSTER_NAME}" \
    --set "settings.interruptionQueue=${CLUSTER_NAME}" \
    --set "settings.clusterEndpoint=$(aws eks describe-cluster --region "${AWS_REGION}" --name "${CLUSTER_NAME}" --query 'cluster.endpoint' --output text)" \
    --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${KARPENTER_CONTROLLER_ROLE_ARN}" \
    --wait \
    || fail "Failed to install Karpenter"

info "Karpenter installed."

###############################################################################
# 2. Apply Karpenter NodePool and EC2NodeClass manifests
###############################################################################
info "=== Step 2: Apply Karpenter NodePool configs ==="

kubectl apply -f "${REPO_ROOT}/kubernetes/karpenter/" \
    || fail "Failed to apply Karpenter NodePool configs"

info "Karpenter NodePool configs applied."

###############################################################################
# 3. Create vLLM namespace and HuggingFace token secret
###############################################################################
info "=== Step 3: Create vllm namespace & HF token secret ==="

kubectl create namespace vllm 2>/dev/null || true

# Retrieve HuggingFace token from AWS Secrets Manager
HF_TOKEN=$(aws secretsmanager get-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "local-llm-llama/hf-token" \
    --query 'SecretString' --output text 2>/dev/null) \
    || fail "Failed to retrieve HF token from Secrets Manager"

kubectl create secret generic hf-token-secret \
    --namespace vllm \
    --from-literal=token="${HF_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f - \
    || fail "Failed to create HF token K8s secret"

unset HF_TOKEN

info "vllm namespace and HF token secret ready."

###############################################################################
# 4. Install AWS Load Balancer Controller (before NLB service)
###############################################################################
info "=== Step 4: Install AWS Load Balancer Controller ==="

LB_CONTROLLER_ROLE_ARN=$(cf_output "${LB_STACK_NAME}" "LBControllerRoleArn")
if [[ -z "${LB_CONTROLLER_ROLE_ARN}" || "${LB_CONTROLLER_ROLE_ARN}" == "None" ]]; then
    fail "Could not retrieve LBControllerRoleArn from stack ${LB_STACK_NAME}"
fi
info "LB Controller role ARN: ${LB_CONTROLLER_ROLE_ARN}"

helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --set clusterName="${CLUSTER_NAME}" \
    --set serviceAccount.create=true \
    --set "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${LB_CONTROLLER_ROLE_ARN}" \
    --set region="${AWS_REGION}" \
    --set vpcId="$(aws ec2 describe-vpcs --region "${AWS_REGION}" --filters "Name=tag:aws:cloudformation:stack-name,Values=${VPC_STACK_NAME}" --query 'Vpcs[0].VpcId' --output text)" \
    --wait \
    || fail "Failed to install AWS Load Balancer Controller"

info "AWS Load Balancer Controller installed."

###############################################################################
# 5. Install vLLM via Helm
###############################################################################
info "=== Step 5: Install vLLM ==="

# Get the vLLM IRSA role ARN and set it in the Helm values
VLLM_ROLE_ARN=$(cf_output "${SECRETS_STACK_NAME}" "VllmRoleArn")
info "vLLM IRSA role ARN: ${VLLM_ROLE_ARN}"

helm repo add vllm https://vllm-project.github.io/production-stack 2>/dev/null || true
helm repo update

helm upgrade --install vllm-local-llm-llama vllm/vllm-stack \
    --namespace vllm \
    --values "${REPO_ROOT}/kubernetes/vllm/values-phase1.yaml" \
    --set "servingEngineSpec.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn=${VLLM_ROLE_ARN}" \
    --wait --timeout 15m \
    || fail "Failed to install vLLM"

info "vLLM deployed."

###############################################################################
# 6. Apply NLB service for external access
###############################################################################
info "=== Step 6: Apply NLB service ==="

kubectl apply -f "${REPO_ROOT}/kubernetes/ingress/vllm-nlb-service.yaml" \
    || fail "Failed to apply NLB service"

info "NLB service applied."

###############################################################################
# 7. Install monitoring stack (Prometheus + Grafana + DCGM Exporter)
###############################################################################
info "=== Step 7: Install monitoring ==="

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts 2>/dev/null || true
helm repo update

kubectl create namespace monitoring 2>/dev/null || true

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --values "${REPO_ROOT}/kubernetes/monitoring/prometheus-values.yaml" \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --wait \
    || fail "Failed to install kube-prometheus-stack"

helm upgrade --install dcgm-exporter gpu-helm-charts/dcgm-exporter \
    --namespace monitoring \
    --values "${REPO_ROOT}/kubernetes/monitoring/dcgm-exporter-values.yaml" \
    --wait \
    || fail "Failed to install dcgm-exporter"

info "Monitoring stack installed."

echo ""
info "=========================================="
info " All Kubernetes resources deployed."
info "=========================================="
