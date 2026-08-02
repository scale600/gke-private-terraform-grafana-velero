# Terraform State Backup — GCS Backend

> **Status**: Proposed (not implemented before decommission)

## Why

Terraform state is the single most critical asset. Without it:
- Cannot run `terraform plan` or `apply`
- Cannot destroy resources cleanly
- All resources become orphaned (manual deletion required)
- IAM bindings and WIF providers are unrecoverable

## Implementation

### `terraform/backend.tf`

```hcl
terraform {
  backend "gcs" {
    bucket = "tf-state-gke-private-demo-202606"
    prefix = "gke-private-demo"
  }
}
```

### `terraform/tf-state-bucket.tf`

```hcl
resource "google_storage_bucket" "tf_state" {
  name                        = "tf-state-${var.project_id}"
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true

  versioning { enabled = true }

  lifecycle_rule {
    action { type = "Delete" }
    condition { num_newer_versions = 100 }
  }
}
```

### Migration Steps

```bash
# 1. Create the bucket manually (chicken-and-egg)
gsutil mb -l us-central1 gs://tf-state-gke-private-demo-202606
gsutil versioning set on gs://tf-state-gke-private-demo-202606

# 2. Add backend block to providers.tf
# 3. Migrate local state to GCS
cd terraform
terraform init -migrate-state

# 4. Verify
terraform state list
```
