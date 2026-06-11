# Phase 3: Velero backup bucket + dedicated SA
resource "google_storage_bucket" "velero" {
  name                        = "${var.cluster_name}-velero-${random_id.suffix.hex}"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    action { type = "Delete" }
    condition { age = 30 }
  }
}

resource "google_service_account" "velero" {
  account_id   = "${var.cluster_name}-velero-sa"
  display_name = "Velero Backup Service Account"
}

resource "google_storage_bucket_iam_member" "velero_bucket_admin" {
  bucket = google_storage_bucket.velero.name
  role   = "roles/storage.admin"
  member = "serviceAccount:${google_service_account.velero.email}"
}

resource "google_project_iam_member" "velero_compute_viewer" {
  project = var.project_id
  role    = "roles/compute.viewer"
  member  = "serviceAccount:${google_service_account.velero.email}"
}
