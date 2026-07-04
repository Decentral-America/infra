#!/usr/bin/env bash
set -e

sudo cp /tmp/prometheus.yml /opt/dcc/monitoring/prometheus.yml
sudo cp /tmp/alerts.yml /opt/dcc/monitoring/alerts.yml
sudo cp /tmp/loki-config.yaml /opt/dcc/monitoring/loki-config.yaml
sudo cp /tmp/config.alloy /opt/dcc/monitoring/config.alloy
sudo cp /tmp/alertmanager.yml /opt/dcc/monitoring/alertmanager.yml
sudo cp /tmp/alert-webhook.py /opt/dcc/monitoring/alert-webhook.py
sudo mkdir -p /opt/dcc/monitoring/datasources
sudo cp /tmp/loki.yaml /opt/dcc/monitoring/datasources/loki.yaml
sudo cp /tmp/prometheus.yaml /opt/dcc/monitoring/datasources/prometheus.yaml
sudo mkdir -p /opt/dcc/compose
sudo cp /tmp/loki-compose.yml /opt/dcc/compose/loki.yml
sudo cp /tmp/prometheus-compose.yml /opt/dcc/compose/prometheus.yml
rm -f /tmp/prometheus.yml /tmp/alerts.yml /tmp/loki-config.yaml \
      /tmp/config.alloy /tmp/alertmanager.yml /tmp/alert-webhook.py \
      /tmp/loki.yaml /tmp/prometheus.yaml /tmp/loki-compose.yml /tmp/prometheus-compose.yml

# Every compose file in /opt/dcc/compose otherwise shares the same default
# Compose project name (the directory basename), so --remove-orphans on one
# service's file treats every OTHER service's containers as orphans and
# deletes them (this took down loki/alertmanager/alert-webhook/promtail
# during the 2026-07-04 redis redeploy incident). Pin isolated project names.
PROMETHEUS_PROJECT="prometheus-testnet"
LOKI_PROJECT="loki-testnet"

# One-time migration: containers created before -p was added to this script
# carry the old directory-based project label ("compose"), which conflicts
# on container name with the newly-project-scoped `up` below (it doesn't
# recognize them as belonging to $PROMETHEUS_PROJECT/$LOKI_PROJECT and tries
# to create a same-named container from scratch). Remove only if the
# existing container's project label doesn't already match the target.
# (promtail-testnet is intentionally absent here: it already carries the
# correct loki-testnet project label from the prior deploy, so
# --remove-orphans below will correctly remove it as a decommissioned
# service now that the alloy migration has replaced it in loki.yml.)
for c in prometheus-testnet:$PROMETHEUS_PROJECT alertmanager-testnet:$PROMETHEUS_PROJECT alert-webhook-testnet:$PROMETHEUS_PROJECT loki-testnet:$LOKI_PROJECT; do
  name="${c%%:*}"; want="${c##*:}"
  have=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2>/dev/null || true)
  if [ -n "$have" ] && [ "$have" != "$want" ]; then
    echo "Removing $name (project '$have' != '$want')..."
    docker rm -f "$name"
  fi
done

echo "=== Restart Prometheus (picks up volume mounts + new config) ==="
NETWORK=testnet docker compose -p "$PROMETHEUS_PROJECT" -f /opt/dcc/compose/prometheus.yml up -d --remove-orphans prometheus
sleep 5
curl -s http://127.0.0.1:9091/api/v1/rules 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
groups=d.get('data',{}).get('groups',[])
print('Rule groups:',len(groups))
for g in groups: print(' ',g.get('name'),':',len(g.get('rules',[])))
" || echo "(prometheus not reachable)"

echo "=== (Re)start Loki + Alloy (removes decommissioned promtail-testnet) ==="
NETWORK=testnet docker compose -p "$LOKI_PROJECT" -f /opt/dcc/compose/loki.yml up -d --remove-orphans
docker ps | grep -E "loki|alloy" || echo "(not running)"
sleep 5
curl -s http://127.0.0.1:3100/ready 2>/dev/null || echo "(loki not ready)"

echo "=== Restart Alertmanager + Alert Webhook ==="
NETWORK=testnet docker compose -p "$PROMETHEUS_PROJECT" -f /opt/dcc/compose/prometheus.yml up -d alertmanager alert-webhook
