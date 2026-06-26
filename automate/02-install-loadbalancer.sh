#!/usr/bin/env bash

set -euo pipefail

# Install AWS Load Balancer Controller on an EKS cluster.
# This script asks for the EKS cluster name, AWS region, and AWS account ID,
# creates the IAM policy and service account, adds the Helm repo, and installs
# the AWS Load Balancer Controller.

echo "=== AWS Load Balancer Controller installer ==="

if ! command -v aws >/dev/null 2>&1; then
  echo "AWS CLI is not installed. Please install it first." >&2
  exit 1
fi

if ! command -v eksctl >/dev/null 2>&1; then
  echo "eksctl is not installed. Please install it first." >&2
  exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "Helm is not installed. Please install it first." >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is not installed. Please install it first." >&2
  exit 1
fi

read -r -p "Enter EKS cluster name: " CLUSTER_NAME
read -r -p "Enter AWS region code (for example us-east-1): " AWS_REGION

if [[ -z "$CLUSTER_NAME" || -z "$AWS_REGION" ]]; then
  echo "Cluster name and region are required." >&2
  exit 1
fi

aws sts get-caller-identity >/dev/null 2>&1 || {
  echo "Invalid AWS credentials" >&2
  exit 1
}

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
POLICY_FILE="iam_policy.json"
EXPECTED_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"

echo
echo "Step 1: Downloading IAM policy..."

# Resolve the latest controller version from Helm to keep the IAM policy in sync
helm repo add eks https://aws.github.io/eks-charts --force-update >/dev/null 2>&1
helm repo update eks >/dev/null 2>&1
LATEST_CHART_VERSION=$(helm search repo eks/aws-load-balancer-controller -o json \
  | jq -r '.[0].version // empty')
CONTROLLER_VERSION="v${LATEST_CHART_VERSION%%.*}.$(echo "$LATEST_CHART_VERSION" | cut -d. -f2).$(echo "$LATEST_CHART_VERSION" | cut -d. -f3)"

curl -fsSL -o "${POLICY_FILE}" \
  "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${CONTROLLER_VERSION}/docs/install/iam_policy.json"

echo "Checking IAM policy..."

EXISTING_POLICY_ARN=$(aws iam list-policies \
  --scope Local \
  --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn | [0]" \
  --output text)

if [[ "$EXISTING_POLICY_ARN" == "None" || -z "$EXISTING_POLICY_ARN" ]]; then
  echo "Creating IAM policy..."
  POLICY_ARN=$(aws iam create-policy \
    --policy-name "${POLICY_NAME}" \
    --policy-document "file://${POLICY_FILE}" \
    --query 'Policy.Arn' \
    --output text)
else
  POLICY_ARN="${EXISTING_POLICY_ARN}"
  echo "Policy already exists: $POLICY_ARN"
fi

aws iam wait policy-exists --policy-arn "$POLICY_ARN"

echo
echo "Step 2: Creating IAM service account for EKS..."

EKSCTL_SUCCESS=false
for i in {1..3}; do
  if eksctl create iamserviceaccount \
    --cluster="${CLUSTER_NAME}" \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --attach-policy-arn="${POLICY_ARN}" \
    --override-existing-serviceaccounts \
    --region "${AWS_REGION}" \
    --approve; then
    EKSCTL_SUCCESS=true
    break
  fi

  echo "Retrying eksctl ($i/3)..."
  sleep 10

done

if [[ "$EKSCTL_SUCCESS" == "false" ]]; then
  echo "eksctl failed after retries" >&2
  exit 1
fi

ROLE_ARN=$(eksctl get iamserviceaccount \
  --cluster "${CLUSTER_NAME}" \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --region "${AWS_REGION}" \
  -o json 2>/dev/null | jq -r '.[0].status.roleARN // empty')

if [[ -z "$ROLE_ARN" ]]; then
  echo "Could not find IAM role ARN for the service account" >&2
  exit 1
fi

echo "Using IAM role: $ROLE_ARN"

if ! kubectl get serviceaccount aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
  echo "Creating K8s service account..."
  kubectl create serviceaccount aws-load-balancer-controller -n kube-system
fi

kubectl annotate serviceaccount aws-load-balancer-controller \
  -n kube-system \
  eks.amazonaws.com/role-arn="${ROLE_ARN}" \
  --overwrite

echo
echo "Step 3: Fetching VPC ID..."

VPC_ID=""
if command -v aws >/dev/null 2>&1; then
  VPC_ID="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
fi

if [[ -z "${VPC_ID}" || "${VPC_ID}" == "None" ]]; then
  echo "Could not determine VPC ID for cluster ${CLUSTER_NAME}." >&2
  exit 1
fi

echo
echo "Step 4: Installing AWS Load Balancer Controller..."

if [[ -z "$LATEST_CHART_VERSION" ]]; then
  echo "Cannot determine Helm chart version" >&2
  exit 1
fi

helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="${CLUSTER_NAME}" \
  --set region="${AWS_REGION}" \
  --set vpcId="${VPC_ID}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set controllerConfig.featureGates.NLBGatewayAPI=true \
  --set controllerConfig.featureGates.ALBGatewayAPI=true \
  --version "${LATEST_CHART_VERSION}"

echo
echo "Step 5: Verifying installation..."
kubectl get deployment -n kube-system aws-load-balancer-controller >/dev/null \
  || {
    echo "Controller deployment not found" >&2
    exit 1
  }

kubectl get deployment -n kube-system aws-load-balancer-controller

echo
echo "Installation completed."
rm -f "${POLICY_FILE}"
