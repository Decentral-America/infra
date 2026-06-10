output "backend_ip" {
  description = "Public IPv4 address of the backend Linode instance"
  value       = tolist(linode_instance.backend.ipv4)[0]
}

output "backend_ipv6" {
  description = "Public IPv6 address of the backend Linode instance"
  value       = linode_instance.backend.ipv6
}

output "network" {
  description = "The active workspace / network"
  value       = local.network
}

output "chain_id" {
  description = "DCC chain ID for this network"
  value       = local.chain_id
}

output "lke_cluster_id" {
  description = "LKE cluster ID (used by CI to download kubeconfig)"
  value       = var.lke_enabled ? linode_lke_cluster.peer_nodes[0].id : null
}


output "lke_kubeconfig" {
  description = "Base64-encoded kubeconfig for the LKE cluster"
  sensitive   = true
  value       = var.lke_enabled ? linode_lke_cluster.peer_nodes[0].kubeconfig : null
}
