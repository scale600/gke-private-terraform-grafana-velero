# Artifact Registry — Docker image mirror (replaces Docker Hub pull via Cloud NAT)
# Free tier: 0.5 GB storage/month. Both nginx:alpine + grafana:11.0.0 fit comfortably.
# Images pulled from AR via Private Google Access — no egress cost within us-central1.

resource "google_artifact_registry_repository" "docker" {
  location      = var.region
  repository_id = "${var.cluster_name}-docker"
  description   = "Mirrored container images for GKE private cluster (no NAT needed)"
  format        = "DOCKER"
}

# Allow node SA to pull images from Artifact Registry
resource "google_artifact_registry_repository_iam_member" "node_reader" {
  repository = google_artifact_registry_repository.docker.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.gke_node.email}"
}

# Allow GitHub Actions SA to push mirrored images to Artifact Registry
resource "google_artifact_registry_repository_iam_member" "github_writer" {
  repository = google_artifact_registry_repository.docker.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.github_actions.email}"
}

output "artifact_registry_repo" {
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.docker.repository_id}"
  description = "Artifact Registry Docker repository path for mirrored images"
}
