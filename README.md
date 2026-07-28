# terraform-vault-platform

Portfolio project: HA HashiCorp Vault cluster on AWS EC2 with Raft
integrated storage and KMS auto-unseal. Provisioned by Terraform, run
by GitHub Actions with OIDC. Same apply-demo-destroy-same-day pattern
as [terraform-eks-platform](https://github.com/bibigon14/terraform-eks-platform).

## Architecture

```mermaid
flowchart TB
    subgraph GH["GitHub Actions"]
        PL[terraform-plan on PR]
        AP[terraform-apply on push to main]
        DS[terraform-destroy manual]
    end

    subgraph AWS["AWS us-west-2"]
        subgraph VPC["VPC 10.30.0.0/16"]
            subgraph PubSub["Public subnets"]
                IGW[Internet Gateway]
                NAT[NAT Gateway]
            end
            subgraph PrivSub["Private subnets (3 AZ)"]
                NLB[Internal NLB :8200]
                subgraph ASG["Auto Scaling Group"]
                    V1[Vault node<br/>us-west-2a]
                    V2[Vault node<br/>us-west-2b]
                    V3[Vault node<br/>us-west-2c]
                end
            end
        end
        KMS[KMS Key<br/>auto-unseal]
        S3[(S3<br/>tfstate)]
        DDB[(DynamoDB<br/>state lock)]
    end

    GH -->|OIDC AssumeRole| AWS
    GH -.->|state| S3
    GH -.->|lock| DDB
    NLB --> ASG
    V1 <-.->|Encrypt/Decrypt| KMS
    V2 <-.->|Encrypt/Decrypt| KMS
    V3 <-.->|Encrypt/Decrypt| KMS
    V1 <-->|Raft| V2
    V2 <-->|Raft| V3
    V1 <-->|Raft| V3
```

## What v1 does

- Three-node Vault OSS cluster on EC2 (t3.medium), one per AZ
- Raft integrated storage, no external DB
- KMS auto-unseal: instances start sealed, come up unsealed within
  ~20 seconds via `awskms` seal type
- Auto-join via EC2 tag discovery (`vault-cluster=<name>`) - no
  hardcoded IPs, ASG replacements rejoin automatically
- Internal NLB with tuned health check (tolerates uninitialized and
  sealed states to avoid the ASG killing nodes before first
  `vault operator init`)
- GitHub Actions with OIDC: plan on PR, apply on merge with manual
  approval on `production` environment, destroy manual with `destroy`
  confirmation input
- Sanitized backend config: state bucket, lock table, and role ARN
  come from GitHub repo variables, not the repo

## Follow-ups (v2 scope, not in this repo)

- Enable TLS at the Vault listener with a self-signed cert
  bootstrapped from the cluster's own PKI after init
- Scope the deploy role down from `AdministratorAccess`
- Second-stage Terraform: PKI root + intermediate CA, database
  secrets engine on RDS Postgres, AWS auth method, policies
- Restrict SG ingress from VPC CIDR to just the NLB + SSM endpoints
- Add `tflint` and `trivy` to the plan workflow
- Pre-commit hooks (`terraform fmt`, `tflint`)

## Getting started

See [docs/bootstrap.md](docs/bootstrap.md) for one-time AWS + GitHub
setup and the full apply/init/destroy walkthrough.

## Walkthrough

The plan workflow comments the full plan on every PR. Merging to
main triggers apply, gated by the `production` environment.

### 1. Environment gate

Apply is blocked until manually approved.

![environment gate](docs/screenshots/01-environment-gate.png)

### 2. Apply in progress

VPC + NAT come up first (slowest), then Vault ASG, then NLB.

![apply in progress](docs/screenshots/02-apply-in-progress.png)

### 3. Apply succeeded

Full stack in ~3-4 minutes on a warm run (5-6 minutes cold).

![apply succeeded](docs/screenshots/03-apply-succeeded.png)

### 4. Cluster verified

After `vault operator init` (see bootstrap.md for the exact steps
that avoid interactive SSM), the cluster reports HA active, three
Raft peers, one leader.

![vault CLI output](docs/screenshots/04-vault-cli-output.png)

### 5. Three-AZ topology

ASG places one instance per availability zone.

![AWS console instances](docs/screenshots/05-aws-console-instances.png)

### 6. Destroy

`terraform destroy` cleans everything except the KMS key, which goes
into the 7-day pending-deletion window.

![destroy succeeded](docs/screenshots/06-destroy-succeeded.png)
