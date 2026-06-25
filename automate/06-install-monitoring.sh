#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITORING_DIR="$SCRIPT_DIR/../observability/monitoring"

PROM_VALUES="$MONITORING_DIR/helm-values/kube-prom-stack-81.6.3.yaml"
GRAFANA_ROUTE="$MONITORING_DIR/HTTProute-grafana.yaml"
PROMETHEUS_ROUTE="$MONITORING_DIR/HTTProute-prometheus.yaml"
TARGET_GRP_GRAFANA="$MONITORING_DIR/target-grp-grafana.yaml"
TARGET_GRP_PROMETHEUS="$MONITORING_DIR/target-grp-prometheus.yaml"

TEMP_PROM_VALUES="$MONITORING_DIR/helm-values/kube-prom-stack-81.6.3.tmp.yaml"
TEMP_GRAFANA_ROUTE="$MONITORING_DIR/HTTProute-grafana.tmp.yaml"
TEMP_PROMETHEUS_ROUTE="$MONITORING_DIR/HTTProute-prometheus.tmp.yaml"

[[ -f "$PROM_VALUES" ]]        || { echo "Error: $PROM_VALUES not found." >&2; exit 1; }
[[ -f "$GRAFANA_ROUTE" ]]      || { echo "Error: $GRAFANA_ROUTE not found." >&2; exit 1; }
[[ -f "$PROMETHEUS_ROUTE" ]]   || { echo "Error: $PROMETHEUS_ROUTE not found." >&2; exit 1; }
[[ -f "$TARGET_GRP_GRAFANA" ]] || { echo "Error: $TARGET_GRP_GRAFANA not found." >&2; exit 1; }
[[ -f "$TARGET_GRP_PROMETHEUS" ]] || { echo "Error: $TARGET_GRP_PROMETHEUS not found." >&2; exit 1; }

cleanup() {
  for f in "$TEMP_PROM_VALUES" "$TEMP_GRAFANA_ROUTE" "$TEMP_PROMETHEUS_ROUTE"; do
    if [[ -f "$f" ]]; then
      rm -f "$f"
      echo "[cleanup] Removed $f"
    fi
  done
}
trap cleanup EXIT

# ── 1. Collect all inputs upfront ───────────────────────────────────────────

read -rp "Enter your Slack Webhook URL (e.g. https://hooks.slack.com/services/...): " SLACK_WEBHOOK
if [[ -z "$SLACK_WEBHOOK" ]]; then
  echo "Error: Slack Webhook URL cannot be empty." >&2
  exit 1
fi
if [[ "$SLACK_WEBHOOK" == *"|"* ]]; then
  echo "Error: Slack Webhook URL must not contain '|'." >&2
  exit 1
fi

read -rp "Enter your Slack channel name (e.g. #alerts): " SLACK_CHANNEL
if [[ -z "$SLACK_CHANNEL" ]]; then
  echo "Error: Slack channel name cannot be empty." >&2
  exit 1
fi
if [[ "$SLACK_CHANNEL" == *"|"* ]]; then
  echo "Error: channel name must not contain '|'." >&2
  exit 1
fi

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
echo "[step 1/7] Creating monitoring namespace..."
kubectl create ns monitoring 2>/dev/null || echo "[info] Namespace 'monitoring' already exists, skipping."

# ── 3. Create Slack webhook secret ──────────────────────────────────────────

echo ""
echo "[step 2/7] Creating Slack webhook secret..."
if kubectl -n monitoring get secret alertmanager-slack-webhook &>/dev/null; then
  echo "[info] Secret 'alertmanager-slack-webhook' already exists, skipping."
else
  kubectl create secret generic alertmanager-slack-webhook \
    --from-literal=slack-webhook-url="$SLACK_WEBHOOK" \
    -n monitoring
  echo "[info] Secret created."
fi

# ── 4. Add Prometheus Community Helm repo ───────────────────────────────────

echo ""
echo "[step 3/7] Adding prometheus-community Helm repo..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

# ── 5. Install kube-prometheus-stack ────────────────────────────────────────

echo ""
echo "[step 4/7] Installing kube-prometheus-stack..."
sed "s|channel: '#alerts'|channel: '${SLACK_CHANNEL}'|g" \
  "$PROM_VALUES" > "$TEMP_PROM_VALUES"
echo "[info] Slack channel set to: ${SLACK_CHANNEL}"

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 81.6.3 \
  -f "$TEMP_PROM_VALUES" \
  -n monitoring

echo ""
echo "[verify] Pods in monitoring namespace (may still be initializing):"
kubectl get po -n monitoring
echo ""
echo "[verify] Services in monitoring namespace:"
kubectl get svc -n monitoring

# ── 6. Deploy Grafana HTTPRoute + target group ───────────────────────────────

echo ""
echo "[step 5/7] Deploying Grafana HTTPRoute..."
sed "s|grafana\.project-cruddur\.com|grafana.${DOMAIN}|g" \
  "$GRAFANA_ROUTE" > "$TEMP_GRAFANA_ROUTE"
echo "[info] Grafana hostname set to: grafana.${DOMAIN}"

kubectl apply -f "$TEMP_GRAFANA_ROUTE"
kubectl apply -f "$TARGET_GRP_GRAFANA"

# ── 7. Deploy Prometheus HTTPRoute + target group ────────────────────────────

echo ""
echo "[step 6/7] Deploying Prometheus HTTPRoute..."
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
echo "[step 7/7] Waiting for Grafana secret..."
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
