#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITORING_DIR="$SCRIPT_DIR/../observability/monitoring"

PROM_VALUES="$MONITORING_DIR/helm-values/kube-prom-stack-81.6.3.yaml"
TEMPO_VALUES="$MONITORING_DIR/helm-values/tempo-values.yaml"
GRAFANA_ROUTE="$MONITORING_DIR/HTTProute-grafana.yaml"
PROMETHEUS_ROUTE="$MONITORING_DIR/HTTProute-prometheus.yaml"
TARGET_GRP_GRAFANA="$MONITORING_DIR/target-grp-grafana.yaml"
TARGET_GRP_PROMETHEUS="$MONITORING_DIR/target-grp-prometheus.yaml"

TEMP_GRAFANA_ROUTE="$MONITORING_DIR/HTTProute-grafana.tmp.yaml"
TEMP_PROMETHEUS_ROUTE="$MONITORING_DIR/HTTProute-prometheus.tmp.yaml"

[[ -f "$PROM_VALUES" ]]        || { echo "Error: $PROM_VALUES not found." >&2; exit 1; }
[[ -f "$TEMPO_VALUES" ]]       || { echo "Error: $TEMPO_VALUES not found." >&2; exit 1; }
[[ -f "$GRAFANA_ROUTE" ]]      || { echo "Error: $GRAFANA_ROUTE not found." >&2; exit 1; }
[[ -f "$PROMETHEUS_ROUTE" ]]   || { echo "Error: $PROMETHEUS_ROUTE not found." >&2; exit 1; }
[[ -f "$TARGET_GRP_GRAFANA" ]] || { echo "Error: $TARGET_GRP_GRAFANA not found." >&2; exit 1; }
[[ -f "$TARGET_GRP_PROMETHEUS" ]] || { echo "Error: $TARGET_GRP_PROMETHEUS not found." >&2; exit 1; }

cleanup() {
  for f in "$TEMP_GRAFANA_ROUTE" "$TEMP_PROMETHEUS_ROUTE"; do
    if [[ -f "$f" ]]; then
      rm -f "$f"
      echo "[cleanup] Removed $f"
    fi
  done
}
trap cleanup EXIT

# ── 1. Collect all inputs upfront ───────────────────────────────────────────

read -rp "Enter your domain (e.g. example.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
  echo "Error: domain cannot be empty." >&2
  exit 1
fi
if [[ "$DOMAIN" == *"|"* ]]; then
  echo "Error: domain must not contain '|'." >&2
  exit 1
fi

# ── 2. Create monitoring namespace ──────────────────────────────────────────

echo ""
echo "[step 1/6] Creating monitoring namespace..."
kubectl create ns monitoring 2>/dev/null || echo "[info] Namespace 'monitoring' already exists, skipping."

# ── 3. Add Helm repos ───────────────────────────────────────────────────────

echo ""
echo "[step 2/6] Adding Helm repos..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update prometheus-community grafana

# ── 4. Install kube-prometheus-stack ────────────────────────────────────────

echo ""
echo "[step 3/6] Installing kube-prometheus-stack..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 81.6.3 \
  -f "$PROM_VALUES" \
  -n monitoring

echo ""
echo "[verify] Pods in monitoring namespace (may still be initializing):"
kubectl get po -n monitoring
echo ""
echo "[verify] Services in monitoring namespace:"
kubectl get svc -n monitoring

# ── 4. Install Tempo ─────────────────────────────────────────────────────────

echo ""
echo "[step 4/6] Installing Tempo..."
helm upgrade --install tempo grafana/tempo \
  --namespace monitoring \
  -f "$TEMPO_VALUES"

# ── 5. Deploy Grafana HTTPRoute + target group ───────────────────────────────

echo ""
echo "[step 5/6] Deploying Grafana HTTPRoute..."
sed "s|grafana\.project-cruddur\.com|grafana.${DOMAIN}|g" \
  "$GRAFANA_ROUTE" > "$TEMP_GRAFANA_ROUTE"
echo "[info] Grafana hostname set to: grafana.${DOMAIN}"

kubectl apply -f "$TEMP_GRAFANA_ROUTE"
kubectl apply -f "$TARGET_GRP_GRAFANA"

# ── 6. Deploy Prometheus HTTPRoute + target group ────────────────────────────

echo ""
echo "[step 6/6] Deploying Prometheus HTTPRoute..."
sed "s|prometheus\.project-cruddur\.com|prometheus.${DOMAIN}|g" \
  "$PROMETHEUS_ROUTE" > "$TEMP_PROMETHEUS_ROUTE"
echo "[info] Prometheus hostname set to: prometheus.${DOMAIN}"

kubectl apply -f "$TEMP_PROMETHEUS_ROUTE"
kubectl apply -f "$TARGET_GRP_PROMETHEUS"

# ── 8. Final verification ────────────────────────────────────────────────────

echo ""
echo "[verify] Final verification..."
echo ""
echo "[verify] TargetGroupConfigurations in monitoring namespace:"
kubectl get targetgroupconfiguration -n monitoring 2>/dev/null \
  || echo "[warn] No TargetGroupConfiguration resources found yet."

echo ""
echo "[verify] HTTPRoutes in monitoring namespace:"
kubectl get httproute -n monitoring 2>/dev/null \
  || echo "[warn] No HTTPRoute resources found yet."

echo ""
echo "[step 6/6] Waiting for Grafana secret..."
for i in $(seq 1 30); do
  if kubectl -n monitoring get secret kube-prometheus-stack-grafana &>/dev/null; then
    break
  fi
  echo "  Waiting for secret... (${i}/30)"
  sleep 5
  if [[ $i -eq 30 ]]; then
    echo "Error: timed out waiting for kube-prometheus-stack-grafana secret." >&2
    exit 1
  fi
done

GRAFANA_PASS=$(kubectl --namespace monitoring get secrets kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d)

echo ""
echo "────────────────────────────────────────"
echo "  Monitoring stack deployed!"
echo "  Grafana:    https://grafana.${DOMAIN}"
echo "  Prometheus: https://prometheus.${DOMAIN}"
echo ""
echo "  Grafana credentials:"
echo "  user: admin"
echo "  pass: ${GRAFANA_PASS}"
echo "────────────────────────────────────────"
