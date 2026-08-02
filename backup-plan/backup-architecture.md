# Backup & Disaster Recovery Plan

> **Project**: GKE Private Demo · **Last Updated**: 2026-08-02 · **Owner**: digitalboosttop

## Table of Contents

1. [Current State Assessment](#1-current-state-assessment)
2. [Gap Analysis](#2-gap-analysis)
3. [Multi-Layer Backup Architecture](#3-multi-layer-backup-architecture)
4. [Implementation Plan](#4-implementation-plan)
5. [Ansible Recovery Playbooks](#5-ansible-recovery-playbooks)
6. [DR Testing Schedule](#6-dr-testing-schedule)
7. [RTO/RPO Targets](#7-rtorpo-targets)

---

## 1. Current State Assessment

### What's Covered

| Layer | Mechanism | RPO | RTO | Status |
|---|---|---|---|---|
| K8s resources (Deployments, Services, ConfigMaps) | Velero v1.18 → GCS daily backup | < 24h | 4s (verified) | ✅ Active |
| GCS objects (app backup bucket) | GCS versioning + 30-day lifecycle | Real-time | < 1min | ✅ Active |
| GCS objects (Velero bucket) | GCS versioning + 30-day lifecycle | Real-time | < 1min | ✅ Active |
| Pod auto-recovery | Deployment controller (Spot preemption) | N/A | < 10s (verified) | ✅ Active |

### What's NOT Covered

| Layer | Current State | Risk |
|---|---|---|
| **Terraform state** | Local file (`terraform.tfstate`) — gitignored | 🔴 If lost, entire infra becomes unreproducible |
| **Container images** | Artifact Registry only | 🟡 GCP regional outage = images unavailable |
| **IAM / WIF config** | Only in Terraform state | 🔴 No state = no IAM recovery path |
| **Cross-region DR** | Everything in `us-central1` | 🔴 Regional outage = total downtime |
| **Automated recovery** | Manual `gcloud` + `kubectl` commands | 🟡 Human-dependent, error-prone |
| **Secret recovery** | Grafana password in local `k8s/grafana-secret.yaml` | 🟡 Lost if local machine fails |
| **GitHub Actions config** | Repository Variables (manual entry) | 🟡 No automated backup of CI/CD config |

---

## 2. Gap Analysis

### 🔴 Critical — Terraform State

Terraform state is the single most critical asset. Without it:
- You cannot run `terraform plan` or `apply`
- You cannot destroy resources cleanly
- All 25 GCP resources become orphaned (manual deletion required)
- IAM bindings and WIF providers are unrecoverable without state

**Current**: Stored locally in `terraform/terraform.tfstate`, gitignored.

### 🟡 High — Cross-Region Resilience

All resources in `us-central1`. A regional outage means:
- GKE cluster unavailable
- GCS buckets unreachable
- Artifact Registry inaccessible
- No path to failover

### 🟡 Medium — Automated Recovery

Current DR runbook is a manual checklist. In a real incident:
- Operator must find the right commands
- Human error risk is high
- Recovery time is unpredictable

---

## 3. Multi-Layer Backup Architecture

```
                         ┌──────────────────────────────────────────┐
                         │          BACKUP LAYERS                   │
                         └──────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│ LAYER 0 — Infrastructure State (Terraform)                              │
│                                                                         │
│  terraform.tfstate ──▶ GCS Bucket (tf-state-{PROJECT})                 │
│  • Versioned + encrypted                                                │
│  • State lock via GCS (no concurrent applies)                           │
│  • Replicated to secondary region                                       │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│ LAYER 1 — Kubernetes Resources (Velero)                                 │
│                                                                         │
│  k8s/* ──▶ Velero Schedule (daily 02:00 UTC) ──▶ GCS                   │
│  • Backup: Deployments, Services, Ingress, ConfigMaps, Secrets, etc.    │
│  • Retention: 30 days                                                   │
│  • GCS versioning: enabled                                              │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│ LAYER 2 — Container Images (Artifact Registry + Mirror)                 │
│                                                                         │
│  Docker images ──▶ us-central1-docker.pkg.dev/...                       │
│  • Multi-region replication (add `us-east1` or `us-west1`)              │
│  • Images also pushed to GitHub Container Registry (ghcr.io)            │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│ LAYER 3 — Configuration & Secrets (Git + GCS)                           │
│                                                                         │
│  GitHub repo ──▶ Git history (natural backup)                           │
│  terraform.tfvars ──▶ GCS (encrypted) or Secret Manager                 │
│  k8s secrets ──▶ Velero backup + GCS                                    │
│  GitHub Actions vars ──▶ Documented in DR runbook                        │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│ LAYER 4 — Cross-Region DR (Optional, for Production)                    │
│                                                                         │
│  us-central1 (Primary)          us-east1 (Standby)                      │
│  ├── GKE cluster                ├── Terraform-only (no running nodes)   │
│  ├── GCS buckets                ├── GCS cross-region replication        │
│  ├── Artifact Registry          ├── Artifact Registry replica           │
│  └── Ingress LB + DNS           └── Standby DNS record (lower TTL)      │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Implementation Plan

### 4.1 Terraform State to GCS (Priority: 🔴 Critical)

**File**: `terraform/backend.tf`

```hcl
terraform {
  backend "gcs" {
    bucket = "tf-state-gke-private-demo-202606"
    prefix = "gke-private-demo"
  }
}
```

**New Terraform resource**: `terraform/tf-state-bucket.tf`

```hcl
# Terraform state bucket — created BEFORE migrating state to GCS
resource "google_storage_bucket" "tf_state" {
  name                        = "tf-state-${var.project_id}"
  location                    = var.region
  force_destroy               = false  # NEVER destroy state bucket
  uniform_bucket_level_access = true

  versioning { enabled = true }

  # Retain all versions — state is small
  lifecycle_rule {
    action { type = "Delete" }
    condition { num_newer_versions = 100 }
  }

  # Encryption at rest
  encryption {
    default_kms_key_name = null  # Google-managed key is sufficient for demo
  }
}
```

**Migration steps**:
```bash
# 1. Create the bucket manually (chicken-and-egg)
gsutil mb -l us-central1 gs://tf-state-gke-private-demo-202606
gsutil versioning set on gs://tf-state-gke-private-demo-202606

# 2. Add backend block to providers.tf
# 3. Migrate local state to GCS
cd terraform
terraform init -migrate-state

# 4. Verify
terraform state list   # Should show all 25 resources
```

### 4.2 Ansible Directory Structure

**New directory**: `ansible/`

```
ansible/
├── ansible.cfg                 # Ansible configuration
├── inventory/
│   └── hosts.yml               # Dynamic inventory via gcloud
├── playbooks/
│   ├── 01-pre-check.yml        # Pre-flight health check
│   ├── 02-restore-terraform.yml # Recreate infra from state
│   ├── 03-restore-k8s.yml      # Restore K8s from Velero
│   ├── 04-restore-dns.yml      # Update Cloudflare DNS
│   ├── 05-verify.yml           # Post-restore verification
│   └── full-dr.yml             # Master playbook (runs all)
├── roles/
│   └── gcp-dr/
│       ├── tasks/
│       │   ├── main.yml
│       │   ├── gke-connect.yml
│       │   ├── velero-restore.yml
│       │   └── verify.yml
│       └── vars/
│           └── main.yml
└── requirements.yml            # Ansible Galaxy dependencies
```

### 4.3 Ansible Playbooks

**`ansible/playbooks/full-dr.yml`** — Master recovery playbook:

```yaml
---
- name: Full Disaster Recovery — GKE Private Demo
  hosts: localhost
  gather_facts: yes
  vars_files:
    - ../roles/gcp-dr/vars/main.yml

  tasks:
    - name: "[1/5] Pre-flight — check GCP auth and tools"
      include_tasks: ../roles/gcp-dr/tasks/pre-check.yml

    - name: "[2/5] Layer 0 — Terraform state check & infra restore"
      include_tasks: ../roles/gcp-dr/tasks/terraform-restore.yml

    - name: "[3/5] Layer 1 — K8s restore via Velero"
      include_tasks: ../roles/gcp-dr/tasks/velero-restore.yml

    - name: "[4/5] Layer 3 — DNS failover (if needed)"
      include_tasks: ../roles/gcp-dr/tasks/dns-failover.yml
      when: dns_failover_needed | default(false)

    - name: "[5/5] Verification — health checks"
      include_tasks: ../roles/gcp-dr/tasks/verify.yml
```

**`ansible/roles/gcp-dr/vars/main.yml`**:

```yaml
---
# GCP Configuration
gcp_project_id: "gke-private-demo-202606"
gcp_zone: "us-central1-f"
gcp_region: "us-central1"
gke_cluster_name: "gke-private-demo"

# Backup
velero_namespace: "velero"
velero_backup_name: "daily-backup"  # Search prefix
gcs_state_bucket: "tf-state-gke-private-demo-202606"

# DNS
cloudflare_zone: "techcloudup.com"
cloudflare_record: "gcp-gke"
ingress_ip: "8.232.180.134"

# Verification
demo_url: "https://gcp-gke.techcloudup.com"
grafana_url: "https://gcp-gke.techcloudup.com/grafana"
health_timeout_seconds: 120
```

**`ansible/roles/gcp-dr/tasks/pre-check.yml`**:

```yaml
---
- name: Verify gcloud CLI is installed
  command: gcloud version
  register: gcloud_version
  changed_when: false

- name: Verify gcloud is authenticated
  command: gcloud auth list --filter="status:ACTIVE" --format="value(account)"
  register: gcloud_account
  changed_when: false

- name: Verify kubectl is installed
  command: kubectl version --client --short
  register: kubectl_version
  changed_when: false
  ignore_errors: yes

- name: Verify velero CLI is installed
  command: velero version --client-only
  register: velero_version
  changed_when: false
  ignore_errors: yes

- name: Verify terraform is installed
  command: terraform version
  register: terraform_version
  changed_when: false

- name: Print tool versions
  debug:
    msg:
      - "gcloud: {{ gcloud_version.stdout }}"
      - "Account: {{ gcloud_account.stdout }}"
      - "kubectl: {{ kubectl_version.stdout | default('NOT INSTALLED') }}"
      - "velero: {{ velero_version.stdout | default('NOT INSTALLED') }}"
      - "terraform: {{ terraform_version.stdout | default('NOT INSTALLED') }}"
```

**`ansible/roles/gcp-dr/tasks/terraform-restore.yml`**:

```yaml
---
- name: Check if Terraform state exists in GCS
  command: gsutil ls gs://{{ gcs_state_bucket }}/gke-private-demo/
  register: state_check
  changed_when: false
  failed_when: false

- name: Pull Terraform state from GCS
  command:
    cmd: gsutil cp gs://{{ gcs_state_bucket }}/gke-private-demo/default.tfstate ../terraform/terraform.tfstate
  when: state_check.rc == 0

- name: Initialize Terraform with GCS backend
  command: terraform init
  args:
    chdir: ../terraform
  register: tf_init

- name: Plan Terraform (check what needs recreation)
  command: terraform plan -var="project_id={{ gcp_project_id }}" -var="github_repo=scale600/gke-private-terraform-grafana-velero"
  args:
    chdir: ../terraform
  register: tf_plan
  changed_when: false

- name: Apply Terraform (recreate infrastructure)
  command: terraform apply -auto-approve -var="project_id={{ gcp_project_id }}" -var="github_repo=scale600/gke-private-terraform-grafana-velero"
  args:
    chdir: ../terraform
  register: tf_apply
  when: tf_plan.stdout is search('Plan: [1-9]')  # Only apply if changes detected
```

**`ansible/roles/gcp-dr/tasks/velero-restore.yml`**:

```yaml
---
- name: Get GKE credentials
  command:
    cmd: >
      gcloud container clusters get-credentials {{ gke_cluster_name }}
      --zone {{ gcp_zone }}
      --project {{ gcp_project_id }}

- name: Wait for Velero pod to be ready
  command: kubectl wait --for=condition=Ready pod -l component=velero -n {{ velero_namespace }} --timeout=300s
  register: velero_ready
  failed_when: false

- name: List available Velero backups
  command: velero backup get
  register: backup_list

- name: Show available backups
  debug:
    msg: "{{ backup_list.stdout_lines }}"

- name: Find latest completed backup
  shell: |
    velero backup get --output json | \
    jq -r '.items | map(select(.status.phase == "Completed")) | sort_by(.status.completionTimestamp) | last | .metadata.name'
  register: latest_backup

- name: Restore from Velero backup
  command: velero restore create --from-backup {{ latest_backup.stdout }} --wait
  when: latest_backup.stdout != "null" and latest_backup.stdout != ""

- name: Check restore status
  command: velero restore get
  register: restore_status
```

**`ansible/roles/gcp-dr/tasks/verify.yml`**:

```yaml
---
- name: Check node status
  command: kubectl get nodes
  register: nodes
  changed_when: false

- name: Check pod status
  command: kubectl get pods -A
  register: pods
  changed_when: false

- name: Wait for demo-app deployment
  command: kubectl rollout status deployment/demo-app -n default --timeout=120s
  register: demo_rollout
  failed_when: false

- name: Wait for Grafana deployment
  command: kubectl rollout status deployment/grafana -n default --timeout=120s
  register: grafana_rollout
  failed_when: false

- name: Test demo page (HTTP 200)
  uri:
    url: "{{ demo_url }}"
    return_content: yes
  register: demo_response
  failed_when: demo_response.status != 200

- name: Test Grafana page (HTTP 200)
  uri:
    url: "{{ grafana_url }}"
    return_content: yes
  register: grafana_response
  failed_when: grafana_response.status != 200

- name: Print summary
  debug:
    msg:
      - "========================================"
      - " DR RESTORE SUMMARY"
      - "========================================"
      - "Nodes: {{ nodes.stdout_lines | length - 1 }} running"
      - "Demo App: {{ 'OK' if demo_response.status == 200 else 'FAILED' }}"
      - "Grafana: {{ 'OK' if grafana_response.status == 200 else 'FAILED' }}"
      - "========================================"
```

### 4.4 Artifact Registry Multi-Region Replication

**File**: `terraform/artifact-registry.tf` (extend existing)

```hcl
# Add secondary region for DR
resource "google_artifact_registry_repository" "docker_dr" {
  provider      = google.dr
  location      = "us-east1"
  repository_id = "gke-private-demo-docker-dr"
  description   = "DR replica — us-east1"
  format        = "DOCKER"
}
```

```hcl
# providers.tf — add DR region provider alias
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google" {
  alias   = "dr"
  project = var.project_id
  region  = "us-east1"
}
```

### 4.5 Scheduled State Backup (GitHub Actions)

**File**: `.github/workflows/backup-state.yml`

```yaml
name: Backup Terraform State & K8s Config

on:
  schedule:
    - cron: '0 1 * * *'   # Daily at 01:00 UTC
  workflow_dispatch:        # Manual trigger

permissions:
  contents: read
  id-token: write

jobs:
  backup:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4

    - name: Auth to GCP
      uses: google-github-actions/auth@v2
      with:
        workload_identity_provider: ${{ vars.WIF_PROVIDER }}
        service_account: ${{ vars.DEPLOY_SA }}

    - uses: google-github-actions/setup-gcloud@v2

    - name: Backup Terraform state snapshot
      run: |
        gcloud storage cp \
          gs://tf-state-gke-private-demo-202606/gke-private-demo/default.tfstate \
          gs://tf-state-gke-private-demo-202606/gke-private-demo/backups/tfstate-$(date +%Y%m%d-%H%M%S)

    - name: Trigger Velero backup
      run: |
        gcloud container clusters get-credentials ${{ vars.GKE_CLUSTER }} \
          --zone ${{ vars.GKE_ZONE }} --project ${{ vars.PROJECT_ID }}
        velero backup create manual-$(date +%Y%m%d-%H%M%S) --wait

    - name: Export K8s resource manifest backup
      run: |
        gcloud container clusters get-credentials ${{ vars.GKE_CLUSTER }} \
          --zone ${{ vars.GKE_ZONE }} --project ${{ vars.PROJECT_ID }}
        kubectl get all,ingress,configmap,secret,networkpolicy,managedcertificate,backendconfig -n default -o yaml > k8s-snapshot.yaml
        gcloud storage cp k8s-snapshot.yaml gs://gke-private-demo-backup-*/$(date +%Y%m%d)/
```

---

## 5. Ansible Recovery Playbooks

### Usage

```bash
# Install dependencies
pip install ansible google-auth requests

# Full DR recovery (all layers)
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/full-dr.yml

# Individual layers
ansible-playbook ansible/playbooks/01-pre-check.yml      # Health check only
ansible-playbook ansible/playbooks/02-restore-terraform.yml  # Infra only
ansible-playbook ansible/playbooks/03-restore-k8s.yml        # K8s only
ansible-playbook ansible/playbooks/05-verify.yml             # Verify only

# Dry-run mode (see what would happen)
ansible-playbook ansible/playbooks/full-dr.yml --check
```

### Scenario Mapping

| Scenario | Ansible Playbook | Expected RTO |
|---|---|---|
| Accidental `kubectl delete` | `03-restore-k8s.yml` | < 5 min |
| Node pool lost (Spot preemption) | `03-restore-k8s.yml` | < 5 min |
| Cluster deleted | `02-restore-terraform.yml` + `03-restore-k8s.yml` | < 20 min |
| Full project deleted | `full-dr.yml` | < 30 min |
| Regional outage (us-central1) | `full-dr.yml` with `dns_failover_needed=true` | < 45 min |

---

## 6. DR Testing Schedule

| Test | Frequency | Method | Success Criteria |
|---|---|---|---|
| Velero backup verification | Daily (automated) | GitHub Actions `backup-state.yml` | Backup completes, stored in GCS |
| Velero restore test | Weekly | `03-restore-k8s.yml` in isolated namespace | All pods Running within 5 min |
| Terraform state restore | Monthly | `02-restore-terraform.yml` with `--check` | `terraform plan` shows no diffs |
| Full DR simulation | Quarterly | `full-dr.yml` on a separate GCP project | Site accessible within 30 min |
| Cross-region failover | Bi-annual | `full-dr.yml` with `us-east1` project | DNS cutover, HTTPS verified |

---

## 7. RTO/RPO Targets

| Tier | Service | RPO | RTO | Mechanism |
|---|---|---|---|---|
| **Tier 0** | Terraform state | Real-time (GCS versioning) | < 5 min | GCS backend + versioning |
| **Tier 1** | K8s workloads (Deployments, Services, Ingress) | < 24h (daily Velero) | < 10 min | Velero restore |
| **Tier 1** | K8s Secrets & ConfigMaps | < 24h (daily Velero) | < 10 min | Velero restore |
| **Tier 2** | Container images | < 1h (push replication) | < 5 min | Artifact Registry multi-region |
| **Tier 2** | GCS data (backup bucket) | Real-time (versioning) | < 1 min | GCS versioning restore |
| **Tier 3** | GitHub Actions config | Manual (documented) | < 15 min | Re-enter Repository Variables |
| **Tier 3** | Cloudflare DNS | Manual (documented) | < 5 min | Update A record |

---

## Quick Reference Card

```bash
# ─── Emergency Recovery Commands ─────────────────────────────

# 1. Check current state
kubectl get nodes && kubectl get pods -A

# 2. Full recovery (Ansible — recommended)
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/full-dr.yml

# 3. Terraform-only recovery (manual fallback)
cd terraform && terraform init && terraform apply -auto-approve

# 4. Velero-only restore
velero restore create --from-backup $(velero backup get -o json | jq -r '.items[-1].metadata.name') --wait

# 5. Verify
curl -sI https://gcp-gke.techcloudup.com | head -1  # Expect: HTTP/2 200

# 6. Emergency contact
# GCP Support: https://console.cloud.google.com/support
# Billing Account: 0100F8-1BE020-E51383
# Project ID: gke-private-demo-202606
```
