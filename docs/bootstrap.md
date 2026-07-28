# Bootstrap

One-time manual steps before the first `terraform apply`. The state
backend (S3) is reused from the sibling `terraform-eks-platform`
project - only the DynamoDB lock table and the IAM deploy role are
new here.

## 0. Prerequisites and shell env

- AWS account in `us-west-2`
- Local `aws` CLI configured with an admin user
- An existing S3 state bucket (created for a prior project) with
  versioning + encryption + public-access-block
- GitHub OIDC provider
  (`token.actions.githubusercontent.com`) already registered in the
  account

Set these in your shell for the rest of the doc:

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export STATE_BUCKET=<your-state-bucket-name>
export AWS_DEFAULT_REGION=us-west-2
```

## 1. DynamoDB lock table

```bash
aws dynamodb create-table \
  --table-name terraform-vault-platform-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

## 2. IAM deploy role (GitHub OIDC)

Trust policy - variables expand from step 0:

```bash
cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:bibigon14/terraform-vault-platform:*",
            "repo:bibigon14@*/terraform-vault-platform@*:*"
          ]
        }
      }
    }
  ]
}
EOF
```

The **second** sub pattern is what actually matches - this account
emits a customized subject claim
(`repo:bibigon14@ID/repo@ID:event`). Same lesson as the EKS
project - if this pattern is missing, `AssumeRoleWithWebIdentity`
returns AccessDenied and the fix is discoverable only via
CloudTrail.

```bash
aws iam create-role \
  --role-name terraform-vault-platform-deploy \
  --assume-role-policy-document file:///tmp/trust-policy.json

aws iam attach-role-policy \
  --role-name terraform-vault-platform-deploy \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

aws iam get-role \
  --role-name terraform-vault-platform-deploy \
  --query 'Role.Arn' --output text
# Copy the ARN for step 3.

rm /tmp/trust-policy.json
```

## 3. GitHub repo setup

- Create public repo `bibigon14/terraform-vault-platform`
- **Settings → Actions → General → Workflow permissions**: Read and
  write
- **Settings → Secrets and variables → Actions → Variables** - add
  three repo variables:
  - `AWS_ROLE_ARN` - the ARN from step 2
  - `TF_STATE_BUCKET` - your state bucket name
  - `TF_STATE_LOCK_TABLE` - `terraform-vault-platform-tfstate-lock`
- **Settings → Environments** - create `production`:
  - Deployment protection rules → Required reviewers → add
    `bibigon14`
  - Deployment branches → Selected branches → allow `main`

## 4. Local dev (optional)

For running `terraform plan` locally against the same state:

```bash
cat > backend.hcl <<EOF
bucket         = "${STATE_BUCKET}"
key            = "terraform-vault-platform/terraform.tfstate"
region         = "us-west-2"
dynamodb_table = "terraform-vault-platform-tfstate-lock"
encrypt        = true
EOF

terraform init -backend-config=backend.hcl
```

`backend.hcl` is gitignored - never commit it.

## 5. First run

```bash
git checkout -b test/first-plan
git add .
git commit -m "initial commit"
git push origin test/first-plan
# open PR against main - terraform-plan.yml comments the plan
# merge - terraform-apply.yml goes to Waiting on production approval
# approve in Actions UI - apply runs ~8-12 min
```

## 6. Initialize the Vault cluster (first apply only)

After `terraform apply` finishes:

```bash
# find a running instance
aws ec2 describe-instances \
  --filters "Name=tag:vault-cluster,Values=vault-platform-demo" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text

# shell in via SSM (no SSH)
aws ssm start-session --target <instance-id>

# on the node:
sudo -i
export VAULT_ADDR=http://127.0.0.1:8200
vault status  # expects: Initialized=false, Sealed=true

vault operator init \
  -recovery-shares=5 \
  -recovery-threshold=3 \
  -format=json > /tmp/init.json
cat /tmp/init.json
```

Save the 5 **recovery keys** and the **root token** into your
password manager immediately, then:

```bash
shred -u /tmp/init.json
```

Auto-unseal takes 20-30 seconds. Verify:

```bash
vault status                    # Initialized=true, Sealed=false
vault operator raft list-peers  # 3 peers, 1 leader
```

## 7. Reach the Vault API from your laptop

The NLB is internal. Use SSM port-forward:

```bash
aws ssm start-session \
  --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters 'portNumber=["8200"],localPortNumber=["8200"]'

# in another terminal:
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<root-token>
vault status
```

## 8. Destroy

`Actions → terraform-destroy → Run workflow`, type `destroy` in the
input. Approve on the `production` environment. ~5-8 min.

Note: the KMS key stays in a 7-day pending-deletion window. If you
re-apply within that window, the alias `alias/<cluster>-unseal`
will already exist and the apply will fail. Either wait, or
`aws kms cancel-key-deletion --key-id <id>` before re-applying.

## Follow-ups (out of scope for v1)

- Terminate TLS at the Vault listener with a self-signed cert
  bootstrapped from the cluster's own PKI once initialized
- Scope the deploy role down from `AdministratorAccess`
- Add `tflint` and `trivy` steps to the plan workflow
- Restrict SG ingress from VPC CIDR to just the NLB and SSM
  endpoints
- Add pre-commit hooks (`terraform fmt`, `tflint`)
