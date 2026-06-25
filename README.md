# GKE Private Cluster — Terraform IaC · Kubernetes (GKE) · GitHub Actions WIF · Grafana 11 · Velero v1.18 DR

> **Production-grade Kubernetes on GCP** — Terraform IaC → GKE Private Cluster (VPC-native) → GitHub Actions CI/CD with Workload Identity Federation (zero SA keys) → Grafana observability on Cloud Monitoring → Velero disaster recovery → all on Spot e2-small under $14/month. [Live Demo](https://gcp-gke.techcloudup.com) · [Grafana Dashboard](https://gcp-gke.techcloudup.com/grafana)

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

### 📦 Infrastructure as Code (25 GCP Resources)

| Component | Technology | Version | Purpose |
|---|---|---|---|
| Provisioning Engine | **Terraform** | `>= 1.6` | Declarative IaC — all 25 GCP resources managed as code |
| GCP Provider | `hashicorp/google` | `~> 5.0` | Native GCP resource lifecycle (cluster, VPC, IAM, storage) |
| Random ID | `hashicorp/random` | `~> 3.0` | Unique GCS bucket name suffix generation |
| State Backend | Local (`terraform.tfstate`) | — | `.gitignore`'d; GCS backend ready for team collaboration |

**Modules by concern:** `providers.tf` → `vpc.tf` → `gke.tf` → `iam.tf` → `cloud-armor.tf` → `gcs.tf` → `static-ip.tf` → `monitoring.tf` → `velero-gcs.tf` — each file owns one infrastructure domain.

### ☸️ Kubernetes & Container Orchestration (GKE)

| Component | Technology | Version | Purpose |
|---|---|---|---|
| **Kubernetes** | **GKE Private Cluster** | Latest stable | Managed K8s control plane — zonal (`us-central1-f`) = free tier |
| Cluster Networking | VPC-native (alias IP) | — | Pods: `10.20.0.0/20`, Services: `10.30.0.0/20` — no kube-proxy overlay |
| Node Pool | **Spot e2-small** (2 vCPU / 2 GB) | — | `spot = true` (~60-80% cheaper), autoscale `1→2`, explicit pool mgmt |
| Private Nodes | `enable_private_nodes = true` | — | No public IP on nodes — all egress through Cloud NAT |
| Workload Identity | `workload_pool = "PROJECT_ID.svc.id.goog"` | — | KSA↔GSA binding — pods get GCP IAM without key files |
| Node Security | `workload_metadata_config: GKE_METADATA` | — | Workload Identity enabled per-node; legacy endpoints disabled |
| K8s Manifests | `k8s/` directory | — | Deployment, Service (LB + ClusterIP), NetworkPolicy, Ingress, ConfigMap, Secret, BackendConfig, ManagedCertificate, ServiceAccount |

**Kubernetes resources deployed:** `Deployment` (hello-gke ×2 replicas, Grafana ×1, demo-app ×1), `Service` (LoadBalancer + 2× ClusterIP), `Ingress` (L7 routing: `/` → demo, `/grafana` → Grafana), `NetworkPolicy` (pod-level ingress/egress), `ConfigMap` (HTML, nginx.conf, Grafana datasource, dashboard JSON), `Secret` (grafana admin password), `BackendConfig` (health check), `ManagedCertificate` (Google SSL), `ServiceAccount` (grafana KSA with WIF annotation)

### 🌐 Networking & Security

| Component | Technology | Details |
|---|---|---|
| VPC | Custom VPC (`10.0.0.0/24`) | `auto_create_subnetworks = false`, `private_ip_google_access = true` |
| Egress | Cloud NAT + Cloud Router | `AUTO_ONLY` NAT IPs, covers all subnet ranges |
| L7 WAF | **Cloud Armor** | Threat intelligence policy — denies known malicious IPs (priority 1000), default-allow catch-all |
| Ingress | GKE Ingress (L7 Global HTTP(S) LB) | Single anycast IP → path-based routing → Cloud Armor → SSL termination |
| SSL/TLS | Google Managed Certificate | Auto-renewing, domain: `gcp-gke.techcloudup.com`, provisioning ~15-30 min |
| Pod Isolation | **Kubernetes NetworkPolicy** | Default-deny posture — only port 8080 ingress, unrestricted egress per pod |
| IAM | Workload Identity Federation | GitHub Actions OIDC → GCP WIF pool → SA impersonation — **zero long-lived keys** |
| Container Hardening | Pod Security Context | `runAsNonRoot: true`, `runAsUser: 1000`, `drop: [ALL]` capabilities, `readOnlyRootFilesystem` |
| Least Privilege | IAM Role Binding | Node SA: `logging.logWriter` + `monitoring.metricWriter` + `artifactregistry.reader` — minimal scope |

### 🚀 CI/CD Pipeline

| Stage | Tool / Action | Details |
|---|---|---|
| Trigger | **GitHub Actions** (`on: push → main`) | Every push to `main` triggers deploy |
| Auth | `google-github-actions/auth@v2` | WIF OIDC → GCP — no SA key download, no secret rotation |
| Toolchain | `google-github-actions/setup-gcloud@v2` | Installs `gcloud` CLI + `gke-gcloud-auth-plugin` component |
| K8s Auth | `gcloud container clusters get-credentials` | Fetches kubeconfig via GCP IAM (WIF-delegated) |
| Deploy | `kubectl apply -f k8s/` | App deployment → demo page → Grafana monitoring stack |
| Verify | `kubectl rollout status --timeout=120s` | Blocks until deployment healthy or timeout |
| Config | GitHub Repository Variables | `WIF_PROVIDER`, `DEPLOY_SA`, `GKE_CLUSTER`, `GKE_ZONE`, `PROJECT_ID` — no hardcoded values |
| Permissions | `id-token: write` + `contents: read` | Minimal required OIDC token scope |

### 📊 Observability

| Component | Technology | Version | Details |
|---|---|---|---|
| Metrics Collection | **Cloud Monitoring** | Free tier (150 MB/day) | `kubernetes.io/*` metrics auto-ingested from GKE |
| Alerting | Alert Policy (MQL) | — | Node CPU utilization > 80% → notification |
| Visualization | **Grafana** | `11.0.0` | Official Docker image, ClusterIP service (not exposed directly) |
| Auth to GCP | GKE Workload Identity | — | `grafana` KSA annotated → `grafana-sa` GSA — reads Monitoring API |
| Custom Dashboard | GKE Overview (JSON) | — | Pre-provisioned via ConfigMap: Node CPU/Memory, Pod restart count, Running pods |
| Sub-path Routing | `GF_SERVER_ROOT_URL` + `GF_SERVER_SERVE_FROM_SUB_PATH` | — | Grafana served under `/grafana` on the Ingress |
| Public Access | Anonymous Auth (`Viewer` role) | — | Read-only dashboard access for demo — disabled in production |
| Health Check | GKE BackendConfig (`/api/health`) | — | Prevents 502 from Grafana's `/` → `/login` redirect |

### 🔄 Disaster Recovery & Backup

| Component | Technology | Version | Details |
|---|---|---|---|
| Backup Engine | **Velero** + GCP Plugin | `v1.18.1` | Kubernetes-native backup/restore, deployed via CLI (`velero install`) |
| Storage | GCS Bucket | — | Versioned, `uniform_bucket_level_access`, 30-day lifecycle auto-delete |
| Schedule | Velero Schedule CRD | — | Daily at 02:00 UTC, TTL 30 days, namespace: `default` |
| Auth | Workload Identity | — | `velero` KSA → `velero-sa` GSA with `storage.admin` — `--no-secret` flag |
| K8s Resources | `k8s/velero/schedule.yaml` | — | Declarative backup schedule managed via `kubectl apply` |
| **Measured RTO** | Pod auto-recovery (Deployment controller) | — | **< 10 seconds** — kubelet detects failure → recreates pod |
| **Measured RTO** | Velero restore (`velero restore create`) | — | **4 seconds** — full deployment restore from GCS backup |
| **Measured RPO** | Daily schedule | — | **< 24 hours** — maximum data loss window |

### 🌍 Edge & Content Delivery

| Component | Technology | Details |
|---|---|---|
| DNS | **Cloudflare** | A record `gcp-gke` → `8.232.180.134`, Proxy OFF (DNS-only, no CDN caching) |
| Static IP | GCP Global External IP | Free when attached to Load Balancer forwarding rule |
| SSL | Google Managed Certificate | Provisioned after DNS propagates, auto-renewed |
| Demo Page | **nginx:alpine** | ConfigMap-mounted `index.html` + `nginx.conf`, `readOnlyRootFilesystem`, `drop: [ALL]` |
| Styling | Tailwind CSS (CDN) | `https://cdn.tailwindcss.com` for demo page styling |
| Live URL | `https://gcp-gke.techcloudup.com` | `/` → demo page, `/grafana` → Grafana dashboard |

### 💰 Cost Optimization

| Strategy | Implementation | Monthly Savings |
|---|---|---|
| Spot VMs | `spot = true` on node pool | **~60-80%** vs on-demand e2-small |
| Free Control Plane | Zonal cluster (single zone) | **$73.00/mo** saved (regional control plane cost) |
| Free Monitoring | Under 150 MB/day ingestion | **$0** — free tier covers demo workloads |
| Right-Sized Resources | `50m-200m` CPU, `64-128 MiB` memory per pod | Minimal per-pod cost |
| Auto-Delete | GCS 30-day lifecycle rule | No accumulation of stale backup objects |
| Auto-Scaling | `min_node_count = 1`, `max_node_count = 2` | Idles at absolute minimum |
| Free SSL | Google Managed Certificate | **$0** — included with GKE Ingress |
| Free Static IP | Attached to forwarding rule | **$0** — charged only when unattached |
| **Estimated Total** | | **~$10-14/month** |

## Architecture & Technology Decisions

> Why each technology was chosen and what trade-offs were considered.

### Why Terraform (not Pulumi / CloudFormation / gcloud CLI)

- **Declarative state management** — `terraform plan` shows exactly what will change before `apply`, critical for production confidence
- **Provider ecosystem** — `hashicorp/google ~> 5.0` covers all GCP resources natively; no gaps for WIF, Cloud Armor, or GKE
- **Module reusability** — VPC, GKE, IAM patterns are reproducible across projects with minimal variable changes
- **Trade-off**: No native GCP construct library — all resources are raw HCL; acceptable for a personal project, but Pulumi with TypeScript may scale better for teams

### Why GKE (not self-managed K8s / GCE / Cloud Run)

- **Free zonal control plane** — the managed control plane costs $0 for single-zone clusters, vs. self-managed requiring master node maintenance
- **VPC-native networking** — alias IP ranges avoid kube-proxy iptables overhead and integrate directly with GCP firewall rules
- **Workload Identity built-in** — no sidecar injection needed for KSA→GSA mapping; configured via cluster-level `workload_identity_config`
- **Auto-upgrade channels** — GKE handles control plane version upgrades (disabled for demo reproducibility; enabled in production)
- **Trade-off**: Vendor lock-in — migrating to EKS/AKS would require rewriting all infra and security config

### Why Private Cluster (not public nodes)

- **Security posture**: Nodes have no public IP — unreachable from the internet. All kubelet, kube-proxy, and pod traffic stays within VPC
- **Cloud NAT for egress**: Private nodes pull container images (`gcr.io`, `docker.io`) and reach GCP APIs (`monitoring.googleapis.com`) through a single NAT gateway
- **Authorized networks**: Cluster endpoint accessible from authorized IPs only (`enable_private_endpoint = false` for `kubectl` convenience in demo)
- **Trade-off**: Debugging is harder — no direct SSH to nodes from the internet. Must use `kubectl exec` or GCP IAP tunneling in production

### Why Spot VMs (not on-demand / committed use)

- **60-80% cost reduction** vs on-demand e2-small — GCP preempts them with 30-second notice, but Deployment controller auto-recreates pods
- **Graceful degradation**: Spot preemption is a DR scenario by design — Velero backup ensures state can be restored to new nodes
- **Production caveat**: For stateful workloads, use on-demand nodes or a mixed pool (on-demand + Spot) with `podAntiAffinity`

### Why Workload Identity Federation (not SA keys / service account JSON)

- **Zero credential rotation** — no downloaded JSON keys to expire, leak, or rotate
- **OIDC trust chain**: GitHub Actions → GitHub OIDC token → GCP WIF pool → impersonate SA — cryptographic, time-bound, repository-scoped
- **Attribute condition**: `assertion.repository == 'scale600/gcp-gke'` prevents any other repo from assuming the identity
- **Per-env scoping**: `principalSet://` membership limits WIF to a specific repository + branch combination

### Why Grafana (not GCP Cloud Console dashboards / Datadog)

- **Cost**: Grafana runs on the existing Spot node as ClusterIP — $0 additional infrastructure cost. Datadog would add $15+/host/month
- **WIF native auth**: Grafana's Google Cloud Monitoring datasource uses the pod's Workload Identity with zero configuration — reads metrics from `kubernetes.io/*` namespace
- **Sub-path routing**: Served under `/grafana` on the same Ingress as the demo page — single domain, single SSL cert, single Cloud Armor policy
- **Embeddable**: `allow_embedding = true` + `kiosk` mode lets the dashboard render in an iframe on the demo page
- **Trade-off**: No alerting from Grafana itself — depends on Cloud Monitoring native alert policies

### Why Velero (not etcd backup / custom scripts)

- **Kubernetes-native**: Backs up entire API objects (Deployment, Service, ConfigMap, Ingress) — not just raw data
- **GCS integration**: Plug-and-play with GCP plugin + Workload Identity — no credential files required
- **CRD-based scheduling**: `Schedule` CRD declaratively defines backup policy — managed via `kubectl apply` like any other K8s resource
- **Selective restore**: `--include-namespaces` / `--include-resources` flags allow granular recovery — restore only the broken deployment without touching healthy resources
- **Trade-off**: Does not backup PersistentVolume data (no PVs in this project). For stateful apps, pair Velero with volume snapshot plugins

### Why Cloudflare DNS (not GCP Cloud DNS / Route53)

- **Cost**: Cloudflare free tier includes DNS hosting — GCP Cloud DNS charges $0.20/zone/month + $0.40/million queries
- **DNS-only mode**: Proxy OFF means Cloudflare doesn't cache or rewrite responses — GKE Ingress handles all traffic directly

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
