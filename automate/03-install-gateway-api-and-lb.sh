#!/usr/bin/env bash

set -euo pipefail

# Install Gateway API resources and AWS Load Balancer Gateway manifests.
# This script uses the existing files in ../gateway-api.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_DIR="$(cd "${SCRIPT_DIR}/../gateway-api" && pwd)"
TEMPLATES_DIR="${GATEWAY_DIR}/templates"
RENDERED_DIR="${GATEWAY_DIR}/rendered"

mkdir -p "${TEMPLATES_DIR}" "${RENDERED_DIR}"

for file in gateway-class.yaml alb-config.yaml gateway.yaml; do
  if [[ -f "${GATEWAY_DIR}/${file}" ]]; then
    cp "${GATEWAY_DIR}/${file}" "${TEMPLATES_DIR}/${file}"
  fi
 done

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is not installed. Please install it first." >&2
  exit 1
fi

kubectl cluster-info >/dev/null || {
  echo "Kubernetes cluster not reachable" >&2
  exit 1
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is not installed. Please install it first." >&2
  exit 1
fi

if [[ ! -f "${TEMPLATES_DIR}/gateway-class.yaml" || \
      ! -f "${TEMPLATES_DIR}/alb-config.yaml" || \
      ! -f "${TEMPLATES_DIR}/gateway.yaml" ]]; then
  echo "Required template files were not found in ${TEMPLATES_DIR}" >&2
  exit 1
fi

read -r -p "Enter the certificate ARN for the ALB listener: " CERT_ARN
if [[ -z "${CERT_ARN}" ]]; then
  echo "Certificate ARN is required." >&2
  exit 1
fi

read -r -p "Enter the domain name for the Gateway (for example *.website.com): " DOMAIN_NAME
if [[ -z "${DOMAIN_NAME}" ]]; then
  echo "Domain name is required." >&2
  exit 1
fi

if [[ ! "$DOMAIN_NAME" =~ ^\*\.[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
  echo "Invalid domain format. Example: *.website.com" >&2
  exit 1
fi

rm -rf "${RENDERED_DIR}"
mkdir -p "${RENDERED_DIR}"

cd "${GATEWAY_DIR}" || exit 1

python3 - "templates/alb-config.yaml" "${CERT_ARN}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
cert_arn = sys.argv[2]
text = path.read_text(encoding='utf-8')
text = text.replace('CERTIFICATE_ARN_PLACEHOLDER', cert_arn)
tmp_path = Path('rendered') / path.name
(tmp_path.parent).mkdir(exist_ok=True)
tmp_path.write_text(text, encoding='utf-8')
print(f'Wrote rendered ALB config to {tmp_path}')
print(f'Updated {path} with certificate ARN: {cert_arn}')
PY

python3 - "templates/gateway.yaml" "${DOMAIN_NAME}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
value = sys.argv[2]
text = path.read_text(encoding='utf-8')
text = text.replace('DOMAIN_NAME_PLACEHOLDER', value)
tmp_path = Path('rendered') / path.name
(tmp_path.parent).mkdir(exist_ok=True)
tmp_path.write_text(text, encoding='utf-8')
print(f'Wrote rendered Gateway manifest to {tmp_path}')
print(f'Updated {path} with domain: {value}')
PY

echo
echo "Step 1: Installing standard Gateway API CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml || exit 1
kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io --timeout=120s

echo
echo "Step 2: Installing LBC Gateway API CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases/download/v3.4.0/crds.yaml || exit 1
kubectl wait --for=condition=Established crd/httproutes.gateway.networking.k8s.io --timeout=120s

echo
echo "Step 3: Creating GatewayClass..."
kubectl apply -f "${TEMPLATES_DIR}/gateway-class.yaml" || exit 1

echo
echo "Step 4: Creating ALB configuration..."
kubectl apply -f "${RENDERED_DIR}/alb-config.yaml" || exit 1

echo
echo "Step 5: Creating Gateway..."
kubectl apply -f "${RENDERED_DIR}/gateway.yaml" || exit 1

echo
echo "Step 6: Verifying Gateway..."
kubectl get gateway

echo
echo "Gateway API installation completed."

rm -rf "${RENDERED_DIR}"

