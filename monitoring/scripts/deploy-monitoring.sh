#!/usr/bin/env bash
set -e

sudo cp /tmp/prometheus.yml /opt/dcc/monitoring/prometheus.yml
sudo cp /tmp/alerts.yml /opt/dcc/monitoring/alerts.yml
sudo cp /tmp/loki-config.yaml /opt/dcc/monitoring/loki-config.yaml
sudo cp /tmp/promtail-config.yaml /opt/dcc/monitoring/promtail-config.yaml
sudo mkdir -p /opt/dcc/monitoring/datasources
sudo cp /tmp/loki.yaml /opt/dcc/monitoring/datasources/loki.yaml
sudo cp /tmp/prometheus.yaml /opt/dcc/monitoring/datasources/prometheus.yaml
rm -f /tmp/prometheus.yml /tmp/alerts.yml /tmp/loki-config.yaml \
      /tmp/promtail-config.yaml /tmp/loki.yaml /tmp/prometheus.yaml

echo "=== Hot-reload Prometheus ==="
curl -s -X POST http://127.0.0.1:9091/-/reload && echo "Reloaded"
sleep 3
curl -s http://127.0.0.1:9091/api/v1/rules 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
groups=d.get('data',{}).get('groups',[])
print('Rule groups:',len(groups))
for g in groups: print(' ',g.get('name'),':',len(g.get('rules',[])))
" || echo "(prometheus not reachable)"

echo "=== Restart Loki + Promtail ==="
NETWORK=testnet docker compose -f /opt/dcc/compose/loki.yml up -d --remove-orphans
docker ps | grep -E "loki|promtail" || echo "(not running)"
sleep 5
curl -s http://127.0.0.1:3100/ready 2>/dev/null || echo "(loki starting)"
