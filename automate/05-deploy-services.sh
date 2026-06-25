#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(cd "${SCRIPT_DIR}/../k8s" && pwd)"

RENDERED_CONFIGMAP="${K8S_DIR}/configmap.rendered.yaml"
RENDERED_BOOKING="${K8S_DIR}/booking-service/deployment.rendered.yaml"
RENDERED_WORKER="${K8S_DIR}/worker-service/deployment.rendered.yaml"

cleanup() {
  for f in "$RENDERED_CONFIGMAP" "$RENDERED_BOOKING" "$RENDERED_WORKER"; do
    [[ -f "$f" ]] && rm -f "$f" && echo "[cleanup] Removed $f"
  done
}
trap cleanup EXIT

# ── Pre-flight checks ────────────────────────────────────────────────────────

for cmd in kubectl sed; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: $cmd is not installed." >&2; exit 1; }
done

kubectl cluster-info >/dev/null 2>&1 || {
  echo "Error: Kubernetes cluster not reachable. Run aws eks update-kubeconfig first." >&2
  exit 1
}

# ── Collect inputs ───────────────────────────────────────────────────────────

read -rp "Enter AWS Account ID: " ACCOUNT_ID
: "${ACCOUNT_ID:?Account ID is required}"

read -rp "Enter ElastiCache endpoint: " ELASTICACHE_ENDPOINT
: "${ELASTICACHE_ENDPOINT:?ElastiCache endpoint is required}"

read -rp "Enter RDS endpoint: " RDS_ENDPOINT
: "${RDS_ENDPOINT:?RDS endpoint is required}"

read -rsp "Enter RDS password: " RDS_PASSWORD
echo
: "${RDS_PASSWORD:?RDS password is required}"
RDS_PASSWORD_ESCAPED="${RDS_PASSWORD//\\/\\\\}"   # escape \ first
RDS_PASSWORD_ESCAPED="${RDS_PASSWORD_ESCAPED//|/\\|}"  # escape |
RDS_PASSWORD_ESCAPED="${RDS_PASSWORD_ESCAPED//&/\\&}"  # escape &

read -rp "Enter ECR repo URI (e.g. 739623014075.dkr.ecr.ap-southeast-2.amazonaws.com): " ECR_REPO
: "${ECR_REPO:?ECR repo URI is required}"

# ── Step 1: Create namespace ─────────────────────────────────────────────────

echo
echo "[step 1/5] Creating ticketing namespace..."
kubectl apply -f "${K8S_DIR}/namespace.yaml"

# ── Step 2: Apply configmap + secret ─────────────────────────────────────────

echo
echo "[step 2/5] Applying ConfigMap and Secret..."
sed \
  -e "s|<ACCOUNT_ID>|${ACCOUNT_ID}|g" \
  -e "s|ap-southeast-1|ap-southeast-2|g" \
  -e "s|<ELASTICACHE_ENDPOINT>|${ELASTICACHE_ENDPOINT}|g" \
  -e "s|<RDS_ENDPOINT>|${RDS_ENDPOINT}|g" \
  -e "s|<PASSWORD>|${RDS_PASSWORD_ESCAPED}|g" \
  "${K8S_DIR}/configmap.yaml" > "$RENDERED_CONFIGMAP"

kubectl apply -f "$RENDERED_CONFIGMAP"

# ── Step 3: Deploy booking-service ───────────────────────────────────────────

echo
echo "[step 3/5] Deploying booking-service..."
sed "s|<YOUR_ECR_REPO>|${ECR_REPO}|g" \
  "${K8S_DIR}/booking-service/deployment.yaml" > "$RENDERED_BOOKING"

kubectl apply -f "$RENDERED_BOOKING"
kubectl apply -f "${K8S_DIR}/booking-service/service.yaml"
kubectl apply -f "${K8S_DIR}/booking-service/hpa.yaml"
kubectl apply -f "${K8S_DIR}/booking-service/pdb.yaml"

# ── Step 4: Deploy worker-service ────────────────────────────────────────────

echo
echo "[step 4/5] Deploying worker-service..."
sed "s|<YOUR_ECR_REPO>|${ECR_REPO}|g" \
  "${K8S_DIR}/worker-service/deployment.yaml" > "$RENDERED_WORKER"

kubectl apply -f "$RENDERED_WORKER"
kubectl apply -f "${K8S_DIR}/worker-service/hpa.yaml"
kubectl apply -f "${K8S_DIR}/worker-service/pdb.yaml"

# ── Step 5: Verify ───────────────────────────────────────────────────────────

echo
echo "[step 5/5] Verifying deployments..."
kubectl get pods -n ticketing
kubectl get svc -n ticketing
kubectl get httproute -n ticketing
