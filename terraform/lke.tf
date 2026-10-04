# ──────────────────────────────────────────────────────────────────────────────
# LKE peer-node cluster
#
# Provisions a managed Kubernetes cluster for DCC blockchain peer nodes.
# Three StatefulSets are deployed via Flux after cluster creation:
#   dcc-gen-0  generator  P2P :6863
#   dcc-gen-1  generator  P2P :6864
#   dcc-val-0  validator  P2P :6865
#
# Testnet:  LKE standard control plane (free), eu-central
#             primary pool:  1× g6-standard-4 (the 3 peer-node StatefulSets,
#                            Flux, chain metrics-exporter) — no extra pools
# Mainnet:  LKE HA control plane ($60/mo, irreversible), dedicated CPU, 2+ nodes
#           Set lke_ha = true and lke_node_type = "g6-dedicated-2" in mainnet.tfvars
#
# Every pool must be declared here: a pool added by hand in the Linode console is
# invisible to cost review and makes drift-detect.yml fail on every run.
#
# NOTE: UFW is intentionally NOT installed on LKE nodes. Kubelet, kube-proxy,
# and Calico all manage iptables rules directly; UFW would conflict and break
# pod networking. Perimeter filtering is handled solely by linode_firewall below.
# ──────────────────────────────────────────────────────────────────────────────

resource "linode_lke_cluster" "peer_nodes" {
  count = var.lke_enabled ? 1 : 0

  label       = "dcc-peer-${local.network}"
  region      = var.lke_region
  k8s_version = var.lke_k8s_version
  tags        = local.tags

  pool {
    type  = var.lke_node_type
    count = var.lke_node_count
  }

  # Declared after the primary pool so pool ordering matches the live cluster.
  dynamic "pool" {
    for_each = var.lke_extra_pools
    content {
      type   = pool.value.type
      count  = pool.value.count
      labels = pool.value.labels
    }
  }

  control_plane {
    # false = standard (free).  true = HA ($60/mo, 3-replica etcd) — IRREVERSIBLE.
    # Must be set correctly at cluster creation; downgrade is not supported.
    high_availability = var.lke_ha
  }
}

# ── Cloud Firewall for LKE worker nodes ───────────────────────────────────────
# Applied to all nodes in the pool. Layered with Calico NetworkPolicies inside
# the cluster for defence-in-depth.
resource "linode_firewall" "lke_nodes" {
  count = var.lke_enabled ? 1 : 0

  label = "dcc-lke-firewall-${local.network}"

  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  # ── Blockchain P2P ─────────────────────────────────────────────────────────
  inbound {
    label    = "allow-p2p-gen-0"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "6863"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    label    = "allow-p2p-gen-1"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "6864"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    label    = "allow-p2p-val-0"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "6865"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  # ── SSH ────────────────────────────────────────────────────────────────────
  # Restricted to known team IPs. Add additional CIDRs to var.lke_ssh_allowed_ips.
  inbound {
    label    = "allow-ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = var.lke_ssh_allowed_ips
  }

  # ── Kubernetes control plane → worker communication ────────────────────────
  # Linode private network CIDR: 192.168.128.0/17
  # kubelet API — used by kube-apiserver to reach pods and exec/logs
  inbound {
    label    = "allow-kubelet"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "10250"
    ipv4     = ["192.168.128.0/17"]
  }

  # ── Calico CNI node-to-node (internal only) ────────────────────────────────
  # VXLAN encapsulation for pod traffic across nodes
  inbound {
    label    = "allow-calico-vxlan"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "4789"
    ipv4     = ["192.168.128.0/17"]
  }

  # BGP peering between Calico nodes
  inbound {
    label    = "allow-calico-bgp"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "179"
    ipv4     = ["192.168.128.0/17"]
  }

  # Typha (Calico scaling agent, used when node count > 50 — included for mainnet)
  inbound {
    label    = "allow-calico-typha"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "5473"
    ipv4     = ["192.168.128.0/17"]
  }

  # NodePort range — internal only (hostNetwork pods don't use NodePorts,
  # but kube-proxy and health checks do)
  inbound {
    label    = "allow-nodeport-internal"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "30000-32767"
    ipv4     = ["192.168.128.0/17"]
  }

  # (allow-node-exporter, private :9100, was removed with the in-cluster
  # kube-prometheus-stack: nothing in the cluster runs node-exporter now.)


  # ── Chain metrics-exporter NodePort → VPS Prometheus ──────────────────────
  # The VPS Prometheus (the single monitoring plane; there is no in-cluster
  # Prometheus or Grafana) scrapes clusters/testnet/monitoring/metrics-exporter.yaml
  # through this NodePort (job lke-chain in monitoring/prometheus.yml). Source
  # is the backend VPS's own public IPv4, read from linode_instance.backend, so
  # a restored or rebuilt VPS with a new IP needs no tfvars edit, only an apply.
  # The matching VPS egress rule is allow-lke-exporter-out in main.tf.
  #
  # Replaces allow-prom-federate-nodeport (32090, in-cluster Prometheus
  # /federate) and allow-grafana-nodeport (32300, 0.0.0.0/0). Grafana is served
  # by the VPS (compose/grafana.yml behind Caddy), never from the cluster.
  inbound {
    label    = "allow-chain-exporter-nodeport"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = tostring(local.lke_chain_exporter_nodeport)
    ipv4     = local.backend_public_ipv4_cidrs
  }

  tags = local.tags

  # Attach to all nodes in the LKE pool
  linodes = [
    for node in linode_lke_cluster.peer_nodes[0].pool[0].nodes : node.instance_id
  ]

  depends_on = [linode_lke_cluster.peer_nodes]
}

# Public IPv4s of the LKE worker(s) the firewall above is attached to. Feeds the
# VPS egress rule allow-lke-exporter-out (main.tf), so a recreated node's new IP
# is picked up by the next plan instead of living as a literal in this repo.
data "linode_instances" "lke_nodes" {
  count = var.lke_enabled ? 1 : 0

  filter {
    name   = "id"
    values = [for node in linode_lke_cluster.peer_nodes[0].pool[0].nodes : tostring(node.instance_id)]
  }
}

locals {
  # NodePort of the chain metrics-exporter Service. Keep in sync with
  # clusters/testnet/monitoring/metrics-exporter.yaml and
  # .github/workflows/deploy-monitoring-stack.yml (LKE_EXPORTER_NODEPORT).
  lke_chain_exporter_nodeport = 32092

  # Linode's regional private range; excluded so only public addresses are allowed.
  linode_private_ipv4_range = "192.168.128.0/17"

  backend_public_ipv4_cidrs = [
    for ip in linode_instance.backend.ipv4 : "${ip}/32" if !cidrcontains(local.linode_private_ipv4_range, ip)
  ]

  lke_node_public_ipv4_cidrs = var.lke_enabled ? flatten([
    for inst in data.linode_instances.lke_nodes[0].instances : [
      for ip in inst.ipv4 : "${ip}/32" if !cidrcontains(local.linode_private_ipv4_range, ip)
    ]
  ]) : []
}
