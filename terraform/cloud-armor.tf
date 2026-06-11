resource "google_compute_security_policy" "armor" {
  name        = "${var.cluster_name}-threat-policy"
  description = "Threat intelligence: block known malicious IPs"

  rule {
    action   = "deny(403)"
    priority = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["103.21.244.0/22", "185.130.5.0/24"]
      }
    }
    description = "Block known threat IPs"
  }

  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default allow"
  }
}
