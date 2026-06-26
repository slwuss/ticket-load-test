#!/usr/bin/env bash

set -euo pipefail

# Deploy ExternalDNS on EKS using Pod Identity.
# This script creates the IAM policy required for Route53 updates (if missing),
# ensures the eks-pod-identity-agent addon is installed, creates a pod identity
# association for the external-dns service account, and installs ExternalDNS via Helm.
#
# Requires: aws, eksctl, kubectl, helm
# Uses: ../external-dns/policy.json and ../external-dns/external-dns-values-1.20.0.yaml

echo "=== ExternalDNS installer (Pod Identity) ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTERNAL_DNS_DIR="$(cd "${SCRIPT_DIR}/../external-dns" && pwd)"
POLICY_FILE="${EXTERNAL_DNS_DIR}/policy.json"
VALUES_FILE="${EXTERNAL_DNS_DIR}/external-dns-values-1.20.0.yaml"

POLICY_NAME="AllowExternalDNSUpdates"
NAMESPACE="external-dns"
SERVICE_ACCOUNT_NAME="external-dns"
ROLE_NAME="external-dns-pod-identity-role"
CHART_VERSION="1.20.0"

for cmd in aws eksctl kubectl helm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd is not installed. Please install it first." >&2
    exit 1
  fi
done

if [[ ! -f "${POLICY_FILE}" ]]; then
  echo "Policy file not found. Creating ${POLICY_FILE}..."
  cat > "${POLICY_FILE}" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets",
        "route53:ListResourceRecordSets",
        "route53:ListTagsForResources"
      ],
      "Resource": [
        "arn:aws:route53:::hostedzone/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZones"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}
EOF
fi

if [[ ! -f "${VALUES_FILE}" ]]; then
  echo "Values file not found: ${VALUES_FILE}" >&2
  exit 1
fi

aws sts get-caller-identity >/dev/null 2>&1 || {
  echo "Invalid AWS credentials" >&2
  exit 1
}

read -r -p "Enter EKS cluster name: " EKS_CLUSTER_NAME
: "${EKS_CLUSTER_NAME:?EKS cluster name is required}"
export EKS_CLUSTER_NAME

DEFAULT_REGION="$(aws configure get region 2>/dev/null || true)"
read -r -p "Enter AWS region [${DEFAULT_REGION}]: " AWS_REGION
AWS_REGION="${AWS_REGION:-$DEFAULT_REGION}"
: "${AWS_REGION:?AWS_REGION is required}"

echo
echo "Verifying cluster ${EKS_CLUSTER_NAME} in region ${AWS_REGION}..."
aws eks describe-cluster --name "${EKS_CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null || {
  echo "Cluster '${EKS_CLUSTER_NAME}' not found in region '${AWS_REGION}'." >&2
  exit 1
}

CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
if [[ "${CURRENT_CONTEXT}" != *"${EKS_CLUSTER_NAME}"* ]]; then
  echo "Updating kubeconfig for cluster ${EKS_CLUSTER_NAME}..."
  aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER_NAME}"
fi

kubectl cluster-info >/dev/null 2>&1 || {
  echo "Kubernetes cluster not reachable" >&2
  exit 1
}

echo
echo "Step 1: Checking IAM policy ${POLICY_NAME}..."

EXISTING_POLICY_ARN=$(aws iam list-policies \
  --scope Local \
  --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn | [0]" \
  --output text)

if [[ "${EXISTING_POLICY_ARN}" == "None" || -z "${EXISTING_POLICY_ARN}" ]]; then
  echo "Creating IAM policy ${POLICY_NAME}..."
  POLICY_ARN=$(aws iam create-policy \
    --policy-name "${POLICY_NAME}" \
    --policy-document "file://${POLICY_FILE}" \
    --query 'Policy.Arn' \
    --output text 2>/dev/null) || POLICY_ARN=$(aws iam list-policies \
      --scope Local \
      --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn | [0]" \
      --output text)

  if [[ -z "${POLICY_ARN}" || "${POLICY_ARN}" == "None" ]]; then
    echo "Failed to create or find IAM policy ${POLICY_NAME}." >&2
    exit 1
  fi
else
  POLICY_ARN="${EXISTING_POLICY_ARN}"
  echo "Policy already exists: ${POLICY_ARN}"
fi

aws iam wait policy-exists --policy-arn "${POLICY_ARN}"
export POLICY_ARN

echo "Policy ARN: ${POLICY_ARN}"

echo
echo "Step 2: Checking eks-pod-identity-agent addon..."

if aws eks describe-addon \
  --cluster-name "${EKS_CLUSTER_NAME}" \
  --addon-name eks-pod-identity-agent \
  --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "eks-pod-identity-agent addon is already installed."
else
  echo "Creating eks-pod-identity-agent addon..."
  eksctl create addon \
    --cluster "${EKS_CLUSTER_NAME}" \
    --name eks-pod-identity-agent \
    --region "${AWS_REGION}"
fi

echo "Waiting for eks-pod-identity-agent addon to become active..."
aws eks wait addon-active \
  --cluster-name "${EKS_CLUSTER_NAME}" \
  --addon-name eks-pod-identity-agent \
  --region "${AWS_REGION}"

echo
echo "Step 3: Creating namespace ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Step 4: Creating pod identity association for service account ${SERVICE_ACCOUNT_NAME}..."

EXISTING_ASSOCIATION=$(aws eks list-pod-identity-associations \
  --cluster-name "${EKS_CLUSTER_NAME}" \
  --namespace "${NAMESPACE}" \
  --service-account "${SERVICE_ACCOUNT_NAME}" \
  --region "${AWS_REGION}" \
  --query 'associations' --output text)

if [[ -n "${EXISTING_ASSOCIATION}" && "${EXISTING_ASSOCIATION}" != "None" ]]; then
  echo "Pod identity association for ${SERVICE_ACCOUNT_NAME} already exists."
else
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  EXISTING_ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text 2>/dev/null || true)"

  if [[ -n "${EXISTING_ROLE_ARN}" && "${EXISTING_ROLE_ARN}" != "None" ]]; then
    echo "IAM role ${ROLE_NAME} already exists, reusing it..."
    eksctl create podidentityassociation \
      --cluster "${EKS_CLUSTER_NAME}" \
      --namespace "${NAMESPACE}" \
      --service-account-name "${SERVICE_ACCOUNT_NAME}" \
      --role-arn "${EXISTING_ROLE_ARN}" \
      --region "${AWS_REGION}"
  else
    eksctl create podidentityassociation \
      --cluster "${EKS_CLUSTER_NAME}" \
      --namespace "${NAMESPACE}" \
      --service-account-name "${SERVICE_ACCOUNT_NAME}" \
      --role-name "${ROLE_NAME}" \
      --permission-policy-arns "${POLICY_ARN}" \
      --region "${AWS_REGION}"
  fi
fi

echo
echo "Step 5: Adding ExternalDNS Helm repo..."
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ --force-update
helm repo update external-dns

echo
echo "Step 6: Installing ExternalDNS via Helm..."
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER_NAME}" >/dev/null
helm upgrade -i external-dns external-dns/external-dns \
  -n "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  -f "${VALUES_FILE}" \
  --set "env[0].name=AWS_DEFAULT_REGION" \
  --set "env[0].value=${AWS_REGION}"

echo
echo "Step 7: Verifying installation..."
echo "Waiting for ExternalDNS pod to be ready..."
if ! kubectl rollout status deployment/external-dns -n "${NAMESPACE}" --timeout=3m; then
  echo
  echo "Pod did not become ready in time. Checking status..." >&2
  kubectl get pods -n "${NAMESPACE}"
  echo
  kubectl describe pods -n "${NAMESPACE}" | tail -30
  exit 1
fi

kubectl get pod -n "${NAMESPACE}"

echo
echo "ExternalDNS installation completed."
