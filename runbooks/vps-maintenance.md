# VPS package maintenance (testnet main, 50.116.30.244)

`unattended-upgrades` applies Debian security updates by itself. Docker (docker-ce, containerd,
docker-compose-plugin, from download.docker.com) and PostgreSQL (pgdg) are deliberately **not** in its
origins: upgrading them restarts every container (Docker) or the database under BPS and data-service
(PostgreSQL). The main node holds over 2/3 of the committee stake, so a Docker upgrade pauses finality
until main is back. Do these by hand, quarterly or for a security fix, in one window.

## Before
```bash
ssh deploy@50.116.30.244 'apt list --upgradable 2>/dev/null | grep -E "docker-ce|containerd|docker-compose-plugin|postgresql-18"'
curl -s https://testnet-node.decentralchain.io/blocks/height; curl -s https://testnet-node.decentralchain.io/blocks/height/finalized
```

## Docker (restarts every container, main included)
```bash
ssh deploy@50.116.30.244 'sudo apt-get update && sudo apt-get install -y --only-upgrade docker-ce docker-ce-cli containerd.io docker-compose-plugin && docker version --format "{{.Server.Version}}"'
```
All containers come back through their `unless-stopped` policy. The host firewall table `inet dcc_host` is
independent of Docker's chains (Docker rewrites only its own). Then check:
```bash
ssh deploy@50.116.30.244 'docker ps --format "{{.Names}} {{.Status}}" | grep -v healthy; sudo nft list table inet dcc_host | grep -c "policy drop"'
```
Expected: only one-shot `*-init-*` containers listed; `1`. Finality lag returns to ≤ 5 within ~5 minutes.

## PostgreSQL (restarts the database)
```bash
ssh deploy@50.116.30.244 'sudo apt-get install -y --only-upgrade postgresql-18 postgresql-client-18 && sudo -u postgres psql -tAc "select version()"'
ssh deploy@50.116.30.244 'docker restart blockchain-postgres-sync-testnet data-service-testnet data-service-pairs-testnet admin-dashboard-testnet'
```
Then `bps_last_synced_height` must catch up to the chain tip (Grafana or `BpsLagging`).

## Kernel
Linode boots its own kernel (`latest-64bit`), so `/var/run/reboot-required` about a Debian kernel has no
effect; no reboot is needed for kernel packages.

## Before mainnet
Debian 12 is in LTS. Rebuild on Debian 13 before any mainnet use of this host type.
