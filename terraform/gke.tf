resource "google_container_cluster" "private" {
  name            = var.cluster_name
  location        = var.zone
  networking_mode = "VPC_NATIVE"
  network         = google_compute_network.main.id
  subnetwork      = google_compute_subnetwork.main.id

  remove_default_node_pool = true
  initial_node_count       = 1

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods-range"
    services_secondary_range_name = "services-range"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Phase 2: re-enabled for Cloud Monitoring (free tier 150MB/day)
  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  deletion_protection = false
}

resource "google_container_node_pool" "spot" {
  name     = "${var.cluster_name}-spot"
  location = var.zone
  cluster  = google_container_cluster.private.name

  autoscaling {
    min_node_count = 1
    max_node_count = 2
  }

  node_config {
    machine_type = "e2-small"
    spot         = true

    metadata = {
      disable-legacy-endpoints = "true"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/devstorage.read_only",
    ]

    service_account = google_service_account.gke_node.email

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}
