output "cluster_name" {
  value = google_container_cluster.private.name
}

output "cluster_endpoint" {
  value     = google_container_cluster.private.endpoint
  sensitive = true
}

output "node_service_account" {
  value = google_service_account.gke_node.email
}

output "github_sa_email" {
  value = google_service_account.github_actions.email
}

output "wif_provider" {
  value = google_iam_workload_identity_pool_provider.github.name
}

output "backup_bucket" {
  value = google_storage_bucket.backup.name
}

output "ingress_ip" {
  value       = google_compute_global_address.grafana_ingress.address
  description = "Static IP for Grafana Ingress — set this as Cloudflare A record for gcp-gke.techcloudup.com"
}
