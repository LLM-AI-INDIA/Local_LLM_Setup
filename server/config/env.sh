#!/usr/bin/env bash
# Shared environment variables for LLaMA EKS deployment
# Source this file from other scripts: source "$(dirname "$0")/../config/env.sh"
#
# Non-secret configuration only. Credentials are managed via AWS CLI profiles
# and Secrets Manager.

export AWS_REGION="${AWS_REGION:-us-west-2}"
export AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID in .env}"
export CLUSTER_NAME="local-llm-llama-eks"

# CloudFormation stack names
export VPC_STACK_NAME="local-llm-llama-vpc"
export EKS_STACK_NAME="local-llm-llama-eks-cluster"
export ADDONS_STACK_NAME="local-llm-llama-eks-addons"
export KARPENTER_STACK_NAME="local-llm-llama-karpenter-iam"
export SECRETS_STACK_NAME="local-llm-llama-secrets-s3"
export LB_STACK_NAME="local-llm-llama-lb-controller-iam"

# Networking
export VPC_CIDR="10.1.0.0/16"

# Versions
export EKS_VERSION="1.31"
export KARPENTER_VERSION="1.0.0"

# S3 bucket for model weights
export MODEL_BUCKET="local-llm-llama-model-weights-${AWS_ACCOUNT_ID}"

# CloudFormation template directory (relative to repo root)
export CF_TEMPLATE_DIR="cloudformation"

# Kubernetes manifest directory (relative to repo root)
export K8S_DIR="kubernetes"
