# GKE Private Cluster Portfolio Project

GKE 운영 경험 + Terraform + CI/CD + 보안/컴플라이언스 + 인시던트 대응을 직접 구현하는 개인 프로젝트입니다. GCP 무료 티어와 최소 비용(< $11/월)으로 설계되었습니다.

## 프로젝트 목표

> "Terraform으로 Private GKE 클러스터를 구축하고, CI/CD로 샘플 앱을 배포하며, Cloud Armor 보안 정책과 재해 복구 절차를 문서화한다."

| 프로젝트 구성 요소 | 구현 내용 |
|---|---|
| GCP 서비스 (GKE, VPC, IAM, Cloud Storage, Cloud Armor) | ✅ |
| Terraform (IaC) | ✅ |
| CI/CD (GitHub Actions) | ✅ |
| Kubernetes/GKE 운영 | ✅ |
| 보안 / Threat intelligence | ✅ Cloud Armor + Network Policy |
| 인시던트 대응 / DR 준비 | ✅ 시나리오별 DR Runbook |
| 비용 최적화 | ✅ Spot 인스턴스, 무료 티어 최대 활용 |

---

## 아키텍처

```
[GitHub Actions] ──WIF 인증──▶ [GKE Private Cluster]
                                         │
                             ┌───────────┴───────────┐
                             │          VPC           │
                             │  ┌─────────────────┐  │
                             │  │  Private Subnet  │  │
                             │  │  (10.0.0.0/24)  │  │
                             │  │                 │  │
                             │  │  [Node Pool]    │  │
                             │  │  e2-small Spot  │  │
                             │  └────────┬────────┘  │
                             │           │            │
                             │       [Cloud NAT]      │
                             └───────────┴───────────┘
                                         │
                             ┌───────────┴───────────┐
                             │      Cloud Armor       │
                             │  (Threat Intelligence) │
                             └───────────────────────┘

                             ┌───────────────────────┐
                             │     GCS Bucket         │
                             │  (버전관리 + DR 백업)  │
                             └───────────────────────┘
```

---

## 사전 준비

### 활성화할 GCP API

```bash
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  storage.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com
```

### Terraform 실행에 필요한 IAM 역할

```
roles/container.admin
roles/compute.networkAdmin
roles/iam.serviceAccountAdmin
roles/iam.workloadIdentityPoolAdmin
roles/storage.admin
roles/compute.securityAdmin
```

---

## 디렉토리 구조

```
gke-private-demo/
├── terraform/
│   ├── providers.tf        # 프로바이더 버전 + 백엔드
│   ├── variables.tf
│   ├── outputs.tf
│   ├── vpc.tf
│   ├── gke.tf
│   ├── iam.tf              # 노드 SA + GitHub Actions WIF
│   ├── cloud-armor.tf
│   └── gcs.tf
├── k8s/
│   ├── deployment.yaml
│   ├── service.yaml
│   └── network-policy.yaml
├── .github/workflows/
│   └── deploy.yml
└── README.md
```

---

## 인프라 (Terraform)

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

  # 협업/프로덕션 시 활성화 (원격 상태 관리)
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
  description = "GCP 프로젝트 ID"
  type        = string
}

variable "region" {
  description = "GCP 리전"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP 존 (zonal 클러스터 = 컨트롤 플레인 무료)"
  type        = string
  default     = "us-central1-f"
}

variable "cluster_name" {
  description = "GKE 클러스터 이름"
  type        = string
  default     = "gke-private-demo"
}

variable "node_count" {
  description = "초기 노드 수"
  type        = number
  default     = 1
}

variable "github_repo" {
  description = "GitHub 리포지토리 (org/repo 형식)"
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
  location        = var.zone   # zonal = 컨트롤 플레인 무료
  networking_mode = "VPC_NATIVE"
  network         = google_compute_network.main.id
  subnetwork      = google_compute_subnetwork.main.id

  # 기본 노드풀 제거 후 별도 node pool 관리
  remove_default_node_pool = true
  initial_node_count       = 1

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods-range"
    services_secondary_range_name = "services-range"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false   # 로컬에서 kubectl 접근 허용
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # 비용 절감: 데모 전용 — 프로덕션에서는 "logging.googleapis.com/kubernetes" 사용
  logging_service    = "none"
  monitoring_service = "none"

  deletion_protection = false   # 데모 전용 — 프로덕션에서는 true
}

resource "google_container_node_pool" "spot" {
  name     = "${var.cluster_name}-spot"
  location = var.zone
  cluster  = google_container_cluster.private.name

  autoscaling {
    min_node_count = 1   # 데모 가용성을 위해 항상 1개 유지
    max_node_count = 2
  }

  node_config {
    # e2-micro(1GB RAM)는 kubelet + kube-proxy 시스템 오버헤드만으로도 부족
    # e2-small(2GB RAM)이 k8s 워크로드 실행 가능한 실질적 최솟값
    machine_type = "e2-small"
    spot         = true   # ~60-80% 비용 절감

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
      mode = "GKE_METADATA"   # Workload Identity 적용
    }
  }
}
```

### terraform/iam.tf

```hcl
# ── 노드 서비스 어카운트 (최소 권한 원칙) ──────────────────────────────

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
# 장점: 장기 유효 SA 키 없이 OIDC 토큰으로 인증 → 키 유출 위험 제거

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

  # 지정된 리포지토리에서만 인증 허용
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

  # 알려진 악성 IP 차단
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

> **확장 포인트:** rule에 `expr { expression = "evaluatePreconfiguredExpr('xss-stable')" }` 추가 시 WAF(XSS/SQLi 차단) 기능도 구성할 수 있습니다.

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
    enabled = true   # 실수 삭제 복구 가능
  }

  lifecycle_rule {
    action { type = "Delete" }
    condition { age = 30 }   # 30일 후 자동 삭제로 비용 최소화
  }
}

resource "google_storage_bucket_iam_member" "github_backup_writer" {
  bucket = google_storage_bucket.backup.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.github_actions.email}"
}
```

---

## 쿠버네티스 매니페스트

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

Workload Identity Federation 방식 — SA 키 없이 OIDC 토큰으로 인증.

### .github/workflows/deploy.yml

```yaml
name: Deploy to GKE

on:
  push:
    branches: [main]

permissions:
  contents: read
  id-token: write   # WIF 필수

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

#### GitHub Repository Variables 설정

| Variable | 값 예시 |
|---|---|
| `WIF_PROVIDER` | `projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| `DEPLOY_SA` | `gke-private-demo-github-sa@PROJECT_ID.iam.gserviceaccount.com` |
| `GKE_CLUSTER` | `gke-private-demo` |
| `GKE_ZONE` | `us-central1-f` |
| `PROJECT_ID` | `my-project-id` |

> `terraform output wif_provider` 와 `terraform output github_sa_email` 로 값을 확인할 수 있습니다.

---

## DR Runbook

### 시나리오 1: Spot 노드 전체 선점

```bash
# 상태 확인
kubectl get nodes
kubectl get pods -o wide

# 신규 노드 수동 추가 (자동 스케일링 대기 불가 시)
gcloud container clusters resize gke-private-demo \
  --node-pool gke-private-demo-spot \
  --num-nodes 1 \
  --zone us-central1-f

# 파드 재기동
kubectl rollout restart deployment/hello-gke
kubectl rollout status deployment/hello-gke --timeout=120s
```

### 시나리오 2: 클러스터 전체 재생성 (IaC 기반)

```bash
# 1. Terraform으로 인프라 재생성 (약 8-12분 소요)
cd terraform
terraform apply -var="project_id=<PROJECT_ID>" -var="github_repo=<ORG/REPO>"

# 2. kubeconfig 업데이트
gcloud container clusters get-credentials gke-private-demo \
  --zone us-central1-f \
  --project <PROJECT_ID>

# 3. 앱 재배포
kubectl apply -f k8s/

# 4. 서비스 IP 확인
kubectl get svc hello-gke-svc
```

### 시나리오 3: GCS에서 데이터 복구

```bash
# 버킷 목록 조회
gsutil ls gs://gke-private-demo-backup-*/

# 특정 오브젝트 복구
gsutil cp gs://gke-private-demo-backup-<SUFFIX>/backup.tar.gz ./

# 버전 관리된 오브젝트 조회
gsutil ls -a gs://gke-private-demo-backup-<SUFFIX>/
```

---

## 검증 체크리스트

```bash
# 1. 클러스터 접근
gcloud container clusters get-credentials gke-private-demo \
  --zone us-central1-f --project <PROJECT_ID>

# 2. Private 노드 확인 (EXTERNAL-IP가 <none>이어야 함)
kubectl get nodes -o wide

# 3. 파드 상태 확인
kubectl get pods -o wide

# 4. 서비스 엔드포인트 확인
kubectl get svc hello-gke-svc

# 5. 앱 접근 테스트
curl http://$(kubectl get svc hello-gke-svc \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# 6. Network Policy 적용 확인
kubectl describe networkpolicy hello-gke-netpol

# 7. Cloud Armor 정책 확인
gcloud compute security-policies describe gke-private-demo-threat-policy
```

---

## 비용 분석 (월간, USD)

| 항목 | 스펙 | 예상 비용 |
|---|---|---|
| GKE 컨트롤 플레인 | Zonal (1존) | **무료** |
| 노드 (e2-small Spot) | 1개 상시 운영 | ~$5-7 |
| Cloud NAT | 1 VM | ~$1 |
| LoadBalancer Forwarding Rule | 1개 | ~$1.8 |
| Cloud Armor | 기본 정책 1개 | $0.75 |
| GCS 버킷 | < 1GB | ~$0 |
| **합계** | | **< $11/월** |

---

## 구축 순서 체크리스트

### 1단계: GCP 환경 준비

- [x] GCP 프로젝트 생성 및 결제 계정 연결 (`gke-private-demo-202606`)
- [x] 필요한 API 활성화 (`container, compute, storage, iam, iamcredentials`)
- [ ] Terraform 실행용 IAM 역할 부여
- [ ] `gcloud auth application-default login` 로컬 인증 설정

### 2단계: Terraform 초기화 및 인프라 배포

- [ ] `terraform/` 디렉토리에 `terraform.tfvars` 파일 생성
  ```hcl
  project_id  = "my-project-id"
  github_repo = "myorg/myrepo"
  ```
- [ ] `terraform init` 실행
- [ ] `terraform plan` 으로 변경 사항 확인
- [ ] `terraform apply` 로 인프라 배포 (약 8-12분 소요)
- [ ] `terraform output` 으로 생성된 리소스 정보 확인

### 3단계: kubeconfig 설정 및 클러스터 확인

- [ ] `gcloud container clusters get-credentials ...` 로 kubeconfig 설정
- [ ] `kubectl get nodes -o wide` — EXTERNAL-IP가 `<none>` 인지 확인 (Private 노드)
- [ ] `kubectl get namespaces` — 클러스터 정상 동작 확인

### 4단계: 쿠버네티스 매니페스트 배포

- [ ] `kubectl apply -f k8s/deployment.yaml`
- [ ] `kubectl apply -f k8s/service.yaml`
- [ ] `kubectl apply -f k8s/network-policy.yaml`
- [ ] `kubectl rollout status deployment/hello-gke` — 배포 완료 확인
- [ ] `kubectl get svc hello-gke-svc` — LoadBalancer External IP 발급 확인

### 5단계: GitHub Actions CI/CD 연결

- [ ] GitHub Repository Variables에 `WIF_PROVIDER`, `DEPLOY_SA`, `GKE_CLUSTER`, `GKE_ZONE`, `PROJECT_ID` 등록
  - 값은 `terraform output wif_provider`, `terraform output github_sa_email` 로 확인
- [ ] `.github/workflows/deploy.yml` 커밋 후 main 브랜치에 push
- [ ] GitHub Actions 워크플로 실행 성공 확인

### 6단계: 보안 및 동작 검증

- [ ] `curl http://<EXTERNAL_IP>` — 앱 응답 확인
- [ ] `gcloud compute security-policies describe ...` — Cloud Armor 정책 적용 확인
- [ ] `kubectl describe networkpolicy hello-gke-netpol` — Network Policy 확인
- [ ] 차단 IP 목록 중 하나로 curl 시도 → 403 응답 확인

### 7단계: DR 시뮬레이션 (선택)

- [ ] `kubectl delete pod --all` 후 자동 복구 확인
- [ ] `terraform destroy` → `terraform apply` 로 전체 재생성 시간 측정
- [ ] GCS 버킷에 테스트 파일 업로드 후 버전 관리 동작 확인

---

## 프로젝트 소개 (영문)

> *"I built a private GKE cluster using Terraform — full IaC, including VPC, Cloud NAT, IAM service accounts with least-privilege roles, and a GCS bucket with versioning for backups. I used Spot e2-small nodes; e2-micro was too small for the kubelet and kube-proxy overhead, so e2-small at 2GB RAM is the practical minimum. For security, I applied a Cloud Armor policy to block known malicious IPs, added Kubernetes Network Policies to restrict pod traffic, and enforced non-root container execution. The GitHub Actions CI/CD pipeline uses Workload Identity Federation — no long-lived service account keys, which eliminates a common credentials-leak risk. I also wrote a DR runbook covering three scenarios: Spot node preemption, full cluster recreation via Terraform, and GCS object recovery. Everything is codified, so I can rebuild the entire environment in under 12 minutes."*
