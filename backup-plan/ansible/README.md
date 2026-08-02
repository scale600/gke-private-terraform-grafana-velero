# Ansible Recovery Playbooks

> **Status**: Proposed (not implemented before decommission)

## Directory Structure

```
ansible/
├── ansible.cfg
├── inventory/hosts.yml
├── playbooks/
│   ├── 01-pre-check.yml
│   ├── 02-restore-terraform.yml
│   ├── 03-restore-k8s.yml
│   ├── 04-restore-dns.yml
│   ├── 05-verify.yml
│   └── full-dr.yml
├── roles/gcp-dr/
│   ├── tasks/
│   │   ├── main.yml
│   │   ├── gke-connect.yml
│   │   ├── velero-restore.yml
│   │   └── verify.yml
│   └── vars/main.yml
└── requirements.yml
```

## Usage

```bash
# Install dependencies
pip install ansible google-auth requests

# Full DR recovery (all layers)
ansible-playbook -i inventory/hosts.yml playbooks/full-dr.yml

# Individual layers
ansible-playbook playbooks/01-pre-check.yml
ansible-playbook playbooks/02-restore-terraform.yml
ansible-playbook playbooks/03-restore-k8s.yml
ansible-playbook playbooks/05-verify.yml

# Dry-run mode
ansible-playbook playbooks/full-dr.yml --check
```

## Scenario Mapping

| Scenario | Playbook | Expected RTO |
|---|---|---|
| Accidental `kubectl delete` | `03-restore-k8s.yml` | < 5 min |
| Node pool lost | `03-restore-k8s.yml` | < 5 min |
| Cluster deleted | `02-restore-terraform.yml` + `03-restore-k8s.yml` | < 20 min |
| Full project deleted | `full-dr.yml` | < 30 min |
| Regional outage | `full-dr.yml` (dns_failover) | < 45 min |
