# Backup & Disaster Recovery Plan

> **Project**: GKE Private Demo · **Status**: Archived (GKE decommissioned 2026-08-02)  
> **Purpose**: Reference documentation for the backup strategy that was in place

## Folder Structure

```
backup-plan/
├── README.md                       # This file — master index
├── dr-runbook.md                   # DR scenarios & recovery procedures
├── backup-architecture.md          # Multi-layer backup architecture design
├── velero/
│   └── schedule.yaml               # Velero daily backup schedule (CRD)
├── terraform/
│   ├── velero-gcs.tf               # Velero GCS bucket + SA (Terraform)
│   ├── gcs.tf                      # App backup GCS bucket (Terraform)
│   └── tf-state-backend.tf         # Proposed Terraform state GCS backend
├── ansible/
│   ├── full-dr.yml                 # Master recovery playbook
│   ├── vars.yml                    # Configuration variables
│   ├── pre-check.yml               # Pre-flight health check
│   ├── terraform-restore.yml       # Infra restore via Terraform
│   ├── velero-restore.yml          # K8s restore via Velero
│   └── verify.yml                  # Post-restore verification
└── github-actions/
    └── backup-state.yml            # Scheduled state backup workflow
```

## Quick Summary

| Layer | Mechanism | RPO | RTO (verified) |
|---|---|---|---|
| K8s resources | Velero → GCS daily | < 24h | 4s |
| GCS objects | Versioning | Real-time | < 1min |
| Pods | Deployment auto-recovery | N/A | < 10s |
| Terraform state | Local (proposed: GCS backend) | Manual | ~15min |

## Cost When Active

| Component | Monthly Cost |
|---|---|
| GCS (Velero bucket) | ~$0.10 |
| GCS (App backup) | ~$0.02 |
| Velero (runs on existing node) | $0 |
| **Total backup cost** | **~$0.12/month** |

> **Note**: The full GKE infrastructure including all backup systems was decommissioned on 2026-08-02 to eliminate ~$44/month in GCP costs. The site now runs as a static page on GitHub Pages ($0/month). These documents serve as portfolio reference.
