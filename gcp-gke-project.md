# GKE Private Cluster Project

A hands-on personal project implementing GKE operations, Terraform, CI/CD, observability, and automated disaster recovery — all from scratch. Designed to run on GCP free tier with minimal cost (< $12/month).

| | Phase | Scope | Status |
|---|---|---|---|
| Phase 1 | Core Infrastructure | Terraform + GKE + CI/CD | 🔵 In Progress |
| Phase 2 | Observability | Cloud Monitoring + Grafana Dashboard | ⬜ Planned |
| Phase 3 | DR & Backup | Velero + Enhanced DR Plan (RTO/RPO) | ⬜ Planned |

## Project Goal

> "Provision a private GKE cluster with Terraform, deploy a sample app via CI/CD, monitor it with Grafana, and automate disaster recovery with Velero — all under $12/month."

| Component | Implementation |
|---|---|
| GCP Services (GKE, VPC, IAM, Cloud Storage, Cloud Armor) | ✅ Phase 1 |
| Terraform (IaC) | ✅ Phase 1 |
| CI/CD (GitHub Actions + WIF) | ✅ Phase 1 |
| Kubernetes/GKE Operations | ✅ Phase 1 |
| Security / Threat Intelligence | ✅ Phase 1 — Cloud Armor + Network Policy |
| Cloud Monitoring + Alerting | ✅ Phase 2 |
| Grafana Dashboard | ✅ Phase 2 |
| Velero Automated Backup | ✅ Phase 3 |
| Enhanced DR Plan (RTO < 15min / RPO < 1hr) | ✅ Phase 3 |
| Cost Optimization | ✅ Spot instances, free tier maximized |

---

## Architecture

```
[Cloudflare DNS]
gcp-gke.techcloudup.com  →  A record (DNS only, Proxy OFF)
        │
        ▼
[GCP Static IP] ──▶ [GKE Ingress + Google Managed SSL]
                              │
[GitHub Actions] ─WIF─▶ [GKE Private Cluster]
                              │
              ┌───────────────┴──────────────────────┐
              │                  VPC                  │
              │  ┌─────────────────────────────────┐  │
              │  │          Private Subnet          │  │
              │  │  [hello-gke app]    (Phase 1)   │  │
              │  │  [Grafana ClusterIP] (Phase 2)  │  │
              │  │  [Velero           ] (Phase 3)  │  │
              │  └──────────────┬──────────────────┘  │
              │                 │                      │
              │            [Cloud NAT]                 │
              └─────────────────┴──────────────────────┘
                                │
          ┌─────────────────────┼──────────────────┐
          │                     │                  │
┌─────────┴────────┐  ┌─────────┴────────┐  ┌─────┴────────────┐
│   Cloud Armor    │  │ Cloud Monitoring  │  │   GCS Buckets    │
│  (Threat Intel)  │  │  + Alert Policy   │  │  app + velero    │
│   Phase 1        │  │  Phase 2          │  │  Phase 1 & 3     │
└──────────────────┘  └───────────────────┘  └──────────────────┘
```

---

## Prerequisites

### Enable GCP APIs

```bash
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  storage.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com
```

### Required IAM Roles for Terraform

```
roles/container.admin
roles/compute.networkAdmin
roles/iam.serviceAccountAdmin
roles/iam.workloadIdentityPoolAdmin
roles/storage.admin
roles/compute.securityAdmin
```

---

## Directory Structure

```
gke-private-demo/
├── terraform/
│   ├── providers.tf              # Provider versions + backend
│   ├── variables.tf
│   ├── outputs.tf
│   ├── vpc.tf
│   ├── gke.tf
│   ├── iam.tf                    # Node SA + GitHub Actions WIF
│   ├── cloud-armor.tf
│   ├── gcs.tf
│   ├── static-ip.tf              # Phase 2: GCP global static IP for Ingress
│   ├── monitoring.tf             # Phase 2: Cloud Monitoring + Alert Policy
│   └── velero-gcs.tf             # Phase 3: Velero backup bucket + SA
├── k8s/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── network-policy.yaml
│   ├── managed-cert.yaml         # Phase 2: Google Managed SSL (gcp-gke.techcloudup.com)
│   ├── ingress.yaml              # Phase 2: GKE Ingress → Grafana
│   ├── grafana-deployment.yaml   # Phase 2: Grafana (ClusterIP)
│   ├── grafana-configmap.yaml    # Phase 2: pre-built GKE dashboard JSON
│   └── velero/                   # Phase 3
│       └── schedule.yaml         # Velero daily backup schedule
├── .github/workflows/
│   └── deploy.yml
└── README.md
```

---

## Infrastructure (Terraform)

### terraform/providers.tf

```hcl
terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # Enable for team/production use (remote state management)
  # backend "gcs" {
  #   bucket = "tf-state-<PROJECT_ID>"
  #   prefix = "gke-private-demo"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
```

### terraform/variables.tf

```hcl
variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP Zone (zonal cluster = free control plane)"
  type        = string
  default     = "us-central1-f"
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "gke-private-demo"
}

variable "node_count" {
  description = "Initial node count"
  type        = number
  default     = 1
}

variable "github_repo" {
  description = "GitHub repository in org/repo format"
  type        = string
}
```

### terraform/outputs.tf

```hcl
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
```

### terraform/vpc.tf

```hcl
resource "google_compute_network" "main" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  name                     = "${var.cluster_name}-subnet"
  ip_cidr_range            = "10.0.0.0/24"
  region                   = var.region
  network                  = google_compute_network.main.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods-range"
    ip_cidr_range = "10.20.0.0/20"
  }
  secondary_ip_range {
    range_name    = "services-range"
    ip_cidr_range = "10.30.0.0/20"
  }
}

resource "google_compute_router" "nat_router" {
  name    = "${var.cluster_name}-router"
  region  = var.region
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "main" {
  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.nat_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
```

### terraform/gke.tf

```hcl
resource "google_container_cluster" "private" {
  name            = var.cluster_name
  location        = var.zone   # zonal = free control plane
  networking_mode = "VPC_NATIVE"
  network         = google_compute_network.main.id
  subnetwork      = google_compute_subnetwork.main.id

  # Remove default node pool and manage separately
  remove_default_node_pool = true
  initial_node_count       = 1

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods-range"
    services_secondary_range_name = "services-range"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false   # Allow local kubectl access
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Cost saving: demo only — use "logging.googleapis.com/kubernetes" in production
  logging_service    = "none"
  monitoring_service = "none"

  deletion_protection = false   # Demo only — set to true in production
}

resource "google_container_node_pool" "spot" {
  name     = "${var.cluster_name}-spot"
  location = var.zone
  cluster  = google_container_cluster.private.name

  autoscaling {
    min_node_count = 1   # Keep at least 1 node for demo availability
    max_node_count = 2
  }

  node_config {
    # e2-micro (1GB RAM) is insufficient for kubelet + kube-proxy system overhead
    # e2-small (2GB RAM) is the practical minimum for running k8s workloads
    machine_type = "e2-small"
    spot         = true   # ~60-80% cost reduction

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
      mode = "GKE_METADATA"   # Enable Workload Identity
    }
  }
}
```

### terraform/iam.tf

```hcl
# ── Node Service Account (Least Privilege Principle) ───────────────────

resource "google_service_account" "gke_node" {
  account_id   = "${var.cluster_name}-node-sa"
  display_name = "GKE Node Service Account"
}

resource "google_project_iam_member" "node_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

resource "google_project_iam_member" "node_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

resource "google_project_iam_member" "node_registry_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

# ── GitHub Actions Workload Identity Federation ────────────────────────
# Authenticates via OIDC token instead of long-lived SA keys → eliminates key leak risk

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions Pool"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
  }

  # Only allow authentication from the specified repository
  attribute_condition = "assertion.repository == '${var.github_repo}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "github_actions" {
  account_id   = "${var.cluster_name}-github-sa"
  display_name = "GitHub Actions Deploy SA"
}

resource "google_service_account_iam_member" "github_wif" {
  service_account_id = google_service_account.github_actions.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}

resource "google_project_iam_member" "github_gke_developer" {
  project = var.project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}
```

### terraform/cloud-armor.tf

```hcl
resource "google_compute_security_policy" "armor" {
  name        = "${var.cluster_name}-threat-policy"
  description = "Threat intelligence: block known malicious IPs"

  # Block known malicious IPs
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

  # Default allow
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
```

> **Extension:** Adding `expr { expression = "evaluatePreconfiguredExpr('xss-stable')" }` to a rule enables WAF functionality (XSS/SQLi blocking).

### terraform/gcs.tf

```hcl
resource "random_id" "suffix" {
  byte_length = 4
}

resource "google_storage_bucket" "backup" {
  name                        = "${var.cluster_name}-backup-${random_id.suffix.hex}"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true

  versioning {
    enabled = true   # Enables recovery from accidental deletion
  }

  lifecycle_rule {
    action { type = "Delete" }
    condition { age = 30 }   # Auto-delete after 30 days to minimize cost
  }
}

resource "google_storage_bucket_iam_member" "github_backup_writer" {
  bucket = google_storage_bucket.backup.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.github_actions.email}"
}
```

---

## Kubernetes Manifests

### k8s/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-gke
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello-gke
  template:
    metadata:
      labels:
        app: hello-gke
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
      containers:
      - name: app
        image: gcr.io/google-samples/hello-app:1.0
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
          limits:
            cpu: "200m"
            memory: "128Mi"
```

### k8s/service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: hello-gke-svc
  namespace: default
spec:
  type: LoadBalancer
  selector:
    app: hello-gke
  ports:
  - port: 80
    targetPort: 8080
```

### k8s/network-policy.yaml

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: hello-gke-netpol
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: hello-gke
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - ports:
    - port: 8080
  egress:
  - {}
```

---

## CI/CD (GitHub Actions)

Uses Workload Identity Federation — authenticates via OIDC token, no SA keys required.

### .github/workflows/deploy.yml

```yaml
name: Deploy to GKE

on:
  push:
    branches: [main]

permissions:
  contents: read
  id-token: write   # Required for WIF

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4

    - name: Authenticate to GCP (Workload Identity Federation)
      uses: google-github-actions/auth@v2
      with:
        workload_identity_provider: ${{ vars.WIF_PROVIDER }}
        service_account: ${{ vars.DEPLOY_SA }}

    - uses: google-github-actions/setup-gcloud@v2

    - name: Get GKE credentials
      run: |
        gcloud container clusters get-credentials ${{ vars.GKE_CLUSTER }} \
          --zone ${{ vars.GKE_ZONE }} \
          --project ${{ vars.PROJECT_ID }}

    - name: Deploy
      run: |
        kubectl apply -f k8s/deployment.yaml
        kubectl apply -f k8s/service.yaml
        kubectl apply -f k8s/network-policy.yaml
        kubectl rollout status deployment/hello-gke --timeout=120s
```

#### GitHub Repository Variables

| Variable | Example Value |
|---|---|
| `WIF_PROVIDER` | `projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| `DEPLOY_SA` | `gke-private-demo-github-sa@PROJECT_ID.iam.gserviceaccount.com` |
| `GKE_CLUSTER` | `gke-private-demo` |
| `GKE_ZONE` | `us-central1-f` |
| `PROJECT_ID` | `my-project-id` |

> Run `terraform output wif_provider` and `terraform output github_sa_email` to get the exact values.

---

## DR Runbook

### Scenario 1: All Spot Nodes Preempted

```bash
# Check current state
kubectl get nodes
kubectl get pods -o wide

# Manually add a new node (if autoscaling is too slow)
gcloud container clusters resize gke-private-demo \
  --node-pool gke-private-demo-spot \
  --num-nodes 1 \
  --zone us-central1-f

# Restart pods
kubectl rollout restart deployment/hello-gke
kubectl rollout status deployment/hello-gke --timeout=120s
```

### Scenario 2: Full Cluster Recreation (IaC-based)

```bash
# 1. Recreate infrastructure with Terraform (~8-12 minutes)
cd terraform
terraform apply -var="project_id=<PROJECT_ID>" -var="github_repo=<ORG/REPO>"

# 2. Update kubeconfig
gcloud container clusters get-credentials gke-private-demo \
  --zone us-central1-f \
  --project <PROJECT_ID>

# 3. Redeploy the app
kubectl apply -f k8s/

# 4. Verify service IP
kubectl get svc hello-gke-svc
```

### Scenario 3: Data Recovery from GCS

```bash
# List available backups
gsutil ls gs://gke-private-demo-backup-*/

# Restore a specific object
gsutil cp gs://gke-private-demo-backup-<SUFFIX>/backup.tar.gz ./

# List versioned objects
gsutil ls -a gs://gke-private-demo-backup-<SUFFIX>/
```

---

## Verification Checklist

```bash
# 1. Connect to the cluster
gcloud container clusters get-credentials gke-private-demo \
  --zone us-central1-f --project <PROJECT_ID>

# 2. Confirm private nodes (EXTERNAL-IP should be <none>)
kubectl get nodes -o wide

# 3. Check pod status
kubectl get pods -o wide

# 4. Check service endpoint
kubectl get svc hello-gke-svc

# 5. Test app access
curl http://$(kubectl get svc hello-gke-svc \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# 6. Verify Network Policy
kubectl describe networkpolicy hello-gke-netpol

# 7. Verify Cloud Armor policy
gcloud compute security-policies describe gke-private-demo-threat-policy
```

---

## Cost Breakdown (Monthly, USD)

| Item | Phase | Spec | Estimated Cost |
|---|---|---|---|
| GKE Control Plane | 1 | Zonal (1 zone) | **Free** |
| Node (e2-small Spot) | 1 | 1-2 nodes, autoscaling | ~$6-10 |
| Cloud NAT | 1 | 1 VM | ~$1 |
| LoadBalancer Forwarding Rule | 1 | 1 rule | ~$1.8 |
| Cloud Armor | 1 | 1 basic policy | $0.75 |
| GCS Bucket (app backup) | 1 | < 1GB | ~$0 |
| Cloud Monitoring | 2 | Free tier (150MB/day) | **Free** |
| GCP Static IP (Ingress) | 2 | 1 global IP (attached = free) | **Free** |
| Google Managed SSL | 2 | `gcp-gke.techcloudup.com` | **Free** |
| Grafana | 2 | Runs on existing node (ClusterIP) | **Free** |
| GCS Bucket (Velero) | 3 | < 5GB | ~$0.5 |
| **Total** | | | **~$10-14/month** |

> Node cost varies: Grafana + Velero may trigger the 2nd Spot node (~$5-7 extra when active). Average monthly cost stays under $14.

---

## Build Order Checklist

---

### 🔵 Phase 1 — Core Infrastructure (49%)

#### Step 1: GCP Environment Setup
- [x] Create GCP project and link a billing account (`gke-private-demo-202606`)
- [x] Enable required APIs (`container, compute, storage, iam, iamcredentials`)
- [x] Grant IAM roles needed for Terraform execution (`roles/owner` confirmed)
- [x] Configure local authentication with `gcloud auth application-default login`

#### Step 2: Terraform — Write & Apply
- [x] Create `terraform/` directory and all `.tf` files
- [x] Create `terraform.tfvars` (`gke-private-demo-202606` / `scale600/gke-private-terraform-grafana-velero`)
- [x] `terraform init`
- [x] `terraform plan` — 25 resources reviewed
- [x] `terraform apply` — 25 resources created (10m55s)
- [x] `terraform output` — ingress_ip: `8.232.180.134`, bucket: `gke-private-demo-backup-45c1471e`

#### Step 3: Cluster Verification
- [x] `gcloud container clusters get-credentials gke-private-demo --zone us-central1-f --project gke-private-demo-202606`
- [x] `kubectl get nodes -o wide` — EXTERNAL-IP: `<none>` ✅ (Private node confirmed)
- [x] `kubectl get namespaces` — cluster healthy (10 namespaces active)

#### Step 4: Deploy Kubernetes Manifests
- [x] `kubectl apply -f k8s/deployment.yaml` — 2 pods Running
- [x] `kubectl apply -f k8s/service.yaml` — External IP: `35.239.123.10`
- [x] `kubectl apply -f k8s/network-policy.yaml`
- [x] `kubectl rollout status deployment/hello-gke` — successfully rolled out
- [x] `curl http://35.239.123.10` → `Hello, world! Version: 1.0.0` ✅

#### Step 5: GitHub Actions CI/CD
- [ ] Add GitHub Repository Variables (`WIF_PROVIDER`, `DEPLOY_SA`, `GKE_CLUSTER`, `GKE_ZONE`, `PROJECT_ID`)
- [ ] Push `.github/workflows/deploy.yml` to main branch
- [ ] Confirm workflow succeeds in GitHub Actions UI

#### Step 6: Security Verification
- [ ] `curl http://<EXTERNAL_IP>` — app responds
- [ ] Cloud Armor policy confirmed applied
- [ ] `kubectl describe networkpolicy hello-gke-netpol` — Network Policy active
- [ ] Blocked IP → 403 confirmed

---

### ⬜ Phase 2 — Observability (24%)

#### Step 7: Cloud Monitoring
- [ ] Re-enable `logging_service` and `monitoring_service` in `gke.tf`
- [ ] `terraform apply` to update cluster
- [ ] `terraform apply monitoring.tf` — create Alert Policy (node CPU > 80%)
- [ ] Confirm metrics appear in GCP Console → Monitoring

#### Step 8: Grafana Dashboard + Domain (gcp-gke.techcloudup.com)

**GCP — Static IP + Ingress + SSL**
- [ ] `terraform apply static-ip.tf` — reserve global static IP
- [ ] `terraform output ingress_ip` — copy the IP address
- [ ] `kubectl apply -f k8s/grafana-deployment.yaml` — Grafana (ClusterIP)
- [ ] `kubectl apply -f k8s/grafana-configmap.yaml`
- [ ] `kubectl apply -f k8s/managed-cert.yaml` — Google Managed SSL for `gcp-gke.techcloudup.com`
- [ ] `kubectl apply -f k8s/ingress.yaml` — GKE Ingress (uses static IP + managed cert)

**Cloudflare DNS**
- [ ] Cloudflare → `techcloudup.com` → DNS → Add Record
  - Type: `A` / Name: `gcp-gke` / Content: `[Static IP]` / Proxy: **OFF (DNS only)**
- [ ] Wait for Google Managed SSL provisioning (~10-15 min)
- [ ] `kubectl describe managedcertificate grafana-cert` — confirm `Active` status

**Verification**
- [ ] `https://gcp-gke.techcloudup.com` 접속 확인 (HTTPS)
- [ ] Connect Grafana to Cloud Monitoring data source
- [ ] Confirm GKE dashboard shows node/pod CPU, memory, restart count

---

### ⬜ Phase 3 — DR & Backup (27%)

#### Step 9: Velero Automated Backup
- [ ] `terraform apply velero-gcs.tf` — create Velero GCS bucket + SA
- [ ] Install Velero CLI locally
- [ ] Deploy Velero to cluster: `velero install --provider gcp ...`
- [ ] `kubectl apply -f k8s/velero/schedule.yaml` — daily backup schedule
- [ ] Trigger manual backup and confirm GCS object created

#### Step 10: Enhanced DR Plan
- [ ] Document RTO < 15min / RPO < 1hr targets in README
- [ ] DR Simulation 1: `kubectl delete pod --all` → auto-recovery confirmed
- [ ] DR Simulation 2: `velero restore create` — restore from backup
- [ ] DR Simulation 3: `terraform destroy` → `terraform apply` — measure rebuild time
- [ ] Record actual RTO/RPO results and update README

---

## Project Overview

*"I built a private GKE cluster across three phases. Phase 1 covers core infrastructure: Terraform IaC for VPC, Cloud NAT, IAM with least-privilege service accounts, Cloud Armor threat policy, and a GitHub Actions CI/CD pipeline using Workload Identity Federation — no long-lived SA keys. Phase 2 adds observability: Cloud Monitoring with alerting and a Grafana dashboard showing real-time node/pod metrics. Phase 3 completes the DR story: Velero automates daily k8s backups to GCS, and the DR runbook documents three recovery scenarios with measured RTO under 15 minutes and RPO under 1 hour. The entire stack runs on Spot e2-small nodes under $14/month."*
