# Global static IP for GKE Ingress (gcp-gke.techcloudup.com)
# Set this IP as Cloudflare A record with Proxy OFF (DNS only)
resource "google_compute_global_address" "grafana_ingress" {
  name = "${var.cluster_name}-ingress-ip"
}
