resource "google_compute_security_policy" "armor" {
  name        = "${var.cluster_name}-threat-policy"
  description = "Threat intelligence + rate limiting: block known malicious IPs, apply rate limits"

  # Rule 1 — Block known threat IP ranges
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

  # Rule 2 — Rate limiting: 60 requests per 60s per IP (prevents brute-force / scraping)
  rule {
    action   = "throttle"
    priority = 2000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      rate_limit_threshold {
        count        = 60
        interval_sec = 60
      }
      conform_action  = "allow"
      exceed_action   = "deny(429)"
      enforce_on_key  = "IP"
    }
    description = "Rate limit: 60 req/min per IP"
  }

  # Rule 3 — Default allow
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
