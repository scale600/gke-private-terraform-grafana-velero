# DR Runbook

> **Status**: Archived — GKE cluster decommissioned 2026-08-02

## Scenario 1: All Spot Nodes Preempted

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

**Expected RTO**: < 5 min (auto-recovery typically < 10s via Deployment controller)

---

## Scenario 2: Full Cluster Recreation (IaC-based)

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

**Expected RTO**: < 20 min

---

## Scenario 3: Data Recovery from GCS

```bash
# List available backups
gsutil ls gs://gke-private-demo-backup-*/

# Restore a specific object
gsutil cp gs://gke-private-demo-backup-<SUFFIX>/backup.tar.gz ./

# List versioned objects
gsutil ls -a gs://gke-private-demo-backup-<SUFFIX>/
```

**Expected RTO**: < 5 min

---

## Scenario 4: Velero Restore

```bash
# List available backups
velero backup get

# Restore latest completed backup
velero restore create --from-backup \
  $(velero backup get -o json | jq -r '.items | map(select(.status.phase == "Completed")) | sort_by(.status.completionTimestamp) | last | .metadata.name') \
  --wait
```

**Verified RTO**: 4 seconds

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
curl -sI https://gcp-gke.techcloudup.com | head -1

# 6. Verify Network Policy
kubectl describe networkpolicy hello-gke-netpol
```

---

## DR Simulation Results (Verified)

| Simulation | Scenario | Result | RTO |
|---|---|---|---|
| DR-1 | `kubectl delete pod --all` → Deployment auto-recovery | ✅ Passed | < 10s |
| DR-2 | `kubectl delete deployment hello-gke` → Velero restore | ✅ Passed | 4s |

**Measured RTO**: < 10s (auto-recovery) / 4s (Velero restore)  
**Estimated RPO**: < 24h (daily backup schedule)
