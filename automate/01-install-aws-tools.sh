#!/usr/bin/env bash

set -euo pipefail

# Install AWS CLI, kubectl, Helm, and eksctl directly on Linux.
# Usage:
#   chmod +x install-aws-tools-ansible.sh
#   ./install-aws-tools-ansible.sh

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "This script needs root privileges. Run it with sudo or as root." >&2
    exit 1
  fi
else
  SUDO=""
fi

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
else
  echo "Cannot detect Linux distribution." >&2
  exit 1
fi

echo "Detected OS: ${PRETTY_NAME:-$NAME}"

install_prereqs() {
  case "${ID:-}" in
    ubuntu|debian|linuxmint|pop)
      echo "Installing prerequisites with APT..."
      $SUDO apt-get update
      $SUDO apt-get install -y curl unzip wget ca-certificates gnupg lsb-release
      ;;
    rhel|centos|rocky|almalinux|fedora|amzn)
      echo "Installing prerequisites with DNF/YUM..."
      if command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y curl unzip wget ca-certificates
      elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y curl unzip wget ca-certificates
      else
        echo "Neither dnf nor yum was found." >&2
        exit 1
      fi
      ;;
    *)
      echo "Unsupported distribution: ${ID:-unknown}" >&2
      exit 1
      ;;
  esac
}

install_aws_cli() {
  if command -v aws >/dev/null 2>&1; then
    echo "AWS CLI is already installed."
    return
  fi

  echo "Installing AWS CLI v2..."
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR}"' RETURN

  curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${TMP_DIR}/awscliv2.zip"
  unzip -q "${TMP_DIR}/awscliv2.zip" -d "${TMP_DIR}"
  $SUDO "${TMP_DIR}/aws/install" -i /usr/local/aws-cli -b /usr/local/bin
}

install_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    echo "kubectl is already installed."
    return
  fi

  echo "Installing kubectl..."
  KUBECTL_VERSION="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
  curl -L "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl
  $SUDO install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
}

install_helm() {
  if command -v helm >/dev/null 2>&1; then
    echo "Helm is already installed."
    return
  fi

  echo "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | $SUDO bash
}

install_eksctl() {
  if command -v eksctl >/dev/null 2>&1; then
    echo "eksctl is already installed."
    return
  fi

  echo "Installing eksctl..."
  ARCH="$(uname -m)"
  case "${ARCH}" in
    x86_64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;;
  esac

  curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_${ARCH}.tar.gz" | tar -xz -C /tmp
  $SUDO install -m 0755 /tmp/eksctl /usr/local/bin/eksctl
}

install_prereqs
install_aws_cli
install_kubectl
install_helm
install_eksctl

echo
echo "Installed tools:"
aws --version 2>/dev/null || true
kubectl version --client 2>/dev/null || true
helm version --short 2>/dev/null || true
eksctl version 2>/dev/null || true

echo
if command -v aws >/dev/null 2>&1; then
  echo "AWS CLI is available."

  read -r -p "AWS Access Key ID: " AWS_ACCESS_KEY_ID
  read -r -s -p "AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY
  echo
  read -r -p "Default AWS region (optional, e.g. us-east-1): " AWS_REGION

  if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
    echo "Access key and secret key cannot be empty." >&2
    exit 1
  fi

  REGION="${AWS_REGION:-us-east-1}"

  aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
  aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
  aws configure set region "$REGION"
  aws configure set output json

  echo "AWS CLI configuration completed (region: $REGION)."

  echo
  echo "Verifying AWS credentials with sts get-caller-identity..."
  aws sts get-caller-identity

  echo
  read -r -p "EKS region: " EKS_REGION
  read -r -p "EKS cluster name: " EKS_CLUSTER_NAME

  if [[ -z "$EKS_REGION" || -z "$EKS_CLUSTER_NAME" ]]; then
    echo "EKS region and cluster name cannot be empty." >&2
    exit 1
  fi

  echo
  echo "Updating kubeconfig for cluster ${EKS_CLUSTER_NAME} in region ${EKS_REGION}..."
  aws eks update-kubeconfig --region "$EKS_REGION" --name "$EKS_CLUSTER_NAME"

  echo
  echo "Granting EKS cluster admin access to current IAM identity..."
  CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
  echo "Current identity: ${CALLER_ARN}"

  # Create access entry — ignore error if it already exists
  set +e
  CREATE_OUTPUT="$(aws eks create-access-entry \
    --cluster-name "$EKS_CLUSTER_NAME" \
    --principal-arn "$CALLER_ARN" \
    --region "$EKS_REGION" 2>&1)"
  CREATE_EXIT=$?
  set -e

  if [[ $CREATE_EXIT -eq 0 ]]; then
    echo "Access entry created."
  elif echo "$CREATE_OUTPUT" | grep -q "ResourceInUseException"; then
    echo "Access entry already exists."
  else
    echo "ERROR: Failed to create EKS access entry: ${CREATE_OUTPUT}" >&2
    exit 1
  fi

  # Associate admin policy — ignore error if already associated
  set +e
  POLICY_OUTPUT="$(aws eks associate-access-policy \
    --cluster-name "$EKS_CLUSTER_NAME" \
    --principal-arn "$CALLER_ARN" \
    --policy-arn "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy" \
    --access-scope type=cluster \
    --region "$EKS_REGION" 2>&1)"
  POLICY_EXIT=$?
  set -e

  if [[ $POLICY_EXIT -eq 0 ]]; then
    echo "Admin policy granted."
  elif echo "$POLICY_OUTPUT" | grep -q "ResourceInUseException"; then
    echo "Admin policy already associated."
  else
    echo "ERROR: Failed to associate EKS admin policy: ${POLICY_OUTPUT}" >&2
    exit 1
  fi

  echo
  echo "Verifying kubectl access..."
  kubectl get nodes
else
  echo "AWS CLI was not found in PATH after installation." >&2
  exit 1
fi

echo
echo "Installation complete."
