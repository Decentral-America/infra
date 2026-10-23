output "id" {
  description = "Linode ID of the runner host"
  value       = linode_instance.runner.id
}

output "ipv4" {
  description = "Public IPv4 of the runner host"
  value       = local.public_ipv4
}

output "known_hosts" {
  description = "Pinned known_hosts line for the runner host (its host key is generated here, never trust-on-first-use)"
  value       = "${local.public_ipv4} ${trimspace(tls_private_key.host_ed25519.public_key_openssh)}"
}

output "host_key_fingerprint" {
  description = "SHA256 fingerprint of the pinned ed25519 host key"
  value       = tls_private_key.host_ed25519.public_key_fingerprint_sha256
}
