# GKE Private Cluster — Cloud Engineering Project

> Private GKE cluster on GCP, provisioned with Terraform, CI/CD via GitHub Actions + Workload Identity Federation, monitored with Grafana, and backed up with Velero — all under minimal cost.

**Live:** [gcp-gke.techcloudup.com](https://gcp-gke.techcloudup.com) | **Dashboard:** [/grafana](https://gcp-gke.techcloudup.com/grafana)

---

## Overview

| Phase | Scope | Status |
|---|---|---|
| Phase 1 | Core Infrastructure — Terraform + GKE + CI/CD | ✅ Complete |
| Phase 2 | Observability — Cloud Monitoring + Grafana Dashboard | ✅ Complete |
| Phase 3 | DR & Backup — Velero + DR Simulations (RTO/RPO) | ✅ Complete |

## Architecture

```
[Cloudflare DNS]  gcp-gke.techcloudup.com
        |
        v
[GCP Static IP: 8.232.180.134]
        |
        v
[GKE Ingress + Cloud Armor + Google Managed SSL]
        |
        +-- /         -->  [Demo App (nginx)]
        +-- /grafana  -->  [Grafana 11 (ClusterIP)]
                                  |
                           [Cloud Monitoring]
                            GKE WIF --> GSA

[GitHub Actions] -- push to main
        |  WIF (no long-lived SA keys)
        v
[GKE Private Cluster  us-central1-f]
        |
        +-- VPC (10.0.0.0/24)
              +-- Private Nodes (Spot e2-small, autoscale 1->2)
              +-- Cloud NAT (egress)
              +-- GCS Bucket  <-- Velero daily backup
```

## Tech Stack

| Layer | Technology |
|---|---|
| Infrastructure | Terraform ~>5.0, GKE Private Cluster (Zonal), VPC-native networking |
| Compute | Spot e2-small nodes, autoscaling min=1 max=2 |
| Networking | Cloud NAT, Cloud Armor (L7 threat policy), GKE Ingress, Google Managed SSL |
| CI/CD | GitHub Actions, Workload Identity Federation (no SA keys) |
| Security | GKE Workload Identity, Kubernetes Network Policy, Cloud Armor |
| Observability | Cloud Monitoring, Grafana 11.0, custom GKE dashboard |
| DR & Backup | Velero v1.18 + GCP plugin, GCS bucket, daily schedule |
| DNS | Cloudflare (DNS-only, A record for subdomain) |

## Key Results

| Metric | Value |
|---|---|
| GCP resources (Terraform) | 25 |
| RTO — pod auto-recovery | < 10 seconds |
| RTO — Velero restore | 4 seconds |
| RPO | < 24 hours (daily backup) |
| Cost optimization | Spot instances + GCP free tier (minimal cost) |

## Repository Structure

```
.
├── terraform/                  # IaC — all GCP resources
│   ├── main.tf                 # Provider + backend
│   ├── vpc.tf                  # VPC, subnets, Cloud NAT
│   ├── gke.tf                  # Private GKE cluster + node pool
│   ├── iam.tf                  # Service accounts + WIF pool/provider
│   ├── security.tf             # Cloud Armor threat policy
│   ├── static-ip.tf            # Global static IP for Ingress
│   ├── monitoring.tf           # Alert policy (node CPU > 80%)
│   └── velero-gcs.tf           # Velero GCS bucket + SA
│
├── k8s/                        # Kubernetes manifests
│   ├── deployment.yaml         # hello-gke app (2 replicas)
│   ├── service.yaml            # LoadBalancer service
│   ├── network-policy.yaml     # Pod ingress/egress rules
│   ├── grafana-sa.yaml         # KSA with WIF annotation
│   ├── grafana-configmap.yaml  # Datasource + dashboard JSON
│   ├── grafana-backendconfig.yaml  # Health check on /api/health
│   ├── grafana-deployment.yaml # Grafana 11 + Service
│   ├── managed-cert.yaml       # Google Managed SSL
│   ├── ingress.yaml            # GKE Ingress (L7)
│   ├── demo-app.yaml           # Project presentation page
│   └── velero/
│       └── schedule.yaml       # Daily backup schedule
│
└── .github/workflows/
    └── deploy.yml              # CI/CD pipeline (WIF auth)
```

## Phase Details

### Phase 1 — Core Infrastructure

- **VPC**: Custom VPC with secondary ranges for pods/services (VPC-native)
- **GKE**: Private cluster (no public node IPs), zonal (us-central1-f), free control plane
- **Node pool**: Spot e2-small, autoscale 1→2, `remove_default_node_pool=true`
- **Cloud NAT**: Enables private nodes to pull images and reach GCP APIs
- **Cloud Armor**: L7 threat intelligence policy attached to GKE Ingress
- **WIF**: GitHub Actions authenticates via OIDC — zero long-lived credentials
- **Network Policy**: Restricts pod-to-pod traffic, egress to GCP metadata only

### Phase 2 — Observability

- **Cloud Monitoring**: GKE system metrics auto-collected (`kubernetes.io/*`)
- **Grafana 11**: Deployed as ClusterIP, uses GKE Workload Identity to query Cloud Monitoring
- **KSA→GSA binding**: `grafana` KSA annotated with `gke-private-demo-grafana-sa` GSA
- **Ingress**: GKE L7 Load Balancer with static IP + Google Managed SSL + Cloud Armor
- **BackendConfig**: Health check on `/api/health` (fixes 502 from Grafana's `/` redirect)
- **Dashboard**: Node CPU/Memory utilization, Pod restart count, Running pods

### Phase 3 — DR & Backup

- **Velero v1.18**: Installed with GCP plugin, uses Workload Identity (no credential file)
- **GCS bucket**: Versioned, 30-day lifecycle, Velero SA has `storage.admin`
- **Schedule**: Daily backup of `default` namespace at 02:00 UTC, TTL 30 days
- **DR Simulation 1**: `kubectl delete pod --all` → Deployment controller recreates in < 10s
- **DR Simulation 2**: `kubectl delete deployment hello-gke` + `velero restore` → 4s RTO

## Deployment

### Prerequisites

```bash
gcloud auth login
gcloud auth application-default login
terraform init
```

### Terraform Apply

```bash
cd terraform/
terraform apply   # creates all 25 GCP resources (~11 min)
terraform output  # ingress_ip, backup_bucket, velero_bucket
```

### Kubernetes Manifests

```bash
kubectl apply -f k8s/grafana-sa.yaml
kubectl apply -f k8s/grafana-configmap.yaml
kubectl apply -f k8s/grafana-backendconfig.yaml
kubectl apply -f k8s/grafana-deployment.yaml
kubectl apply -f k8s/managed-cert.yaml
kubectl apply -f k8s/ingress.yaml
kubectl apply -f k8s/demo-app.yaml
kubectl apply -f k8s/velero/schedule.yaml
```

### CI/CD

Push to `main` branch triggers GitHub Actions:
1. Authenticate via Workload Identity Federation (no SA key)
2. Get GKE credentials
3. `kubectl apply` all manifests
4. `kubectl rollout status` wait for completion

---

*GKE Private Cluster Project · us-central1-f · Spot e2-small · minimal cost*
