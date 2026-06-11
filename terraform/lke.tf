# ──────────────────────────────────────────────────────────────────────────────
# LKE peer-node cluster
#
# Provisions a managed Kubernetes cluster for DCC blockchain peer nodes.
# Three StatefulSets are deployed via Flux after cluster creation:
#   dcc-gen-0  generator  P2P :6863
#   dcc-gen-1  generator  P2P :6864
#   dcc-val-0  validator  P2P :6865
#
# Testnet:  LKE standard control plane (free), 1× g6-standard-2, eu-central
# Mainnet:  LKE HA control plane ($60/mo, irreversible), dedicated CPU, 2+ nodes
#           Set lke_ha = true and lke_node_type = "g6-dedicated-2" in mainnet.tfvars
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
    label    = "allow-p2p-gen0"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "6863"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    label    = "allow-p2p-gen1"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "6864"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    label    = "allow-p2p-val0"
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

  # Prometheus node-exporter scrape (from within cluster, private net)
  inbound {
    label    = "allow-node-exporter"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "9100"
    ipv4     = ["192.168.128.0/17"]
  }


  inbound {
    label    = "allow-grafana-nodeport"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "32300"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  tags = local.tags

  # Attach to all nodes in the LKE pool
  linodes = [
    for node in linode_lke_cluster.peer_nodes[0].pool[0].nodes : node.instance_id
  ]

  depends_on = [linode_lke_cluster.peer_nodes]
}
