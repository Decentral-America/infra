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
