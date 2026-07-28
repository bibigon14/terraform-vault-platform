# Bootstrap

One-time manual steps before the first `terraform apply`, plus the
full walkthrough of apply, init, and destroy.

## 0. Prerequisites and shell env

- AWS account in `us-west-2`
- Local `aws` CLI configured with an admin user
- An existing S3 state bucket (created for a prior project) with
  versioning + encryption + public-access-block
- GitHub OIDC provider
  (`token.actions.githubusercontent.com`) already registered in the
  account
- `session-manager-plugin` installed
  (`brew install --cask session-manager-plugin`)
- `jq` installed

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

aws dynamodb wait table-exists \
  --table-name terraform-vault-platform-tfstate-lock
```

## 2. IAM deploy role (GitHub OIDC)

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
(`repo:bibigon14@ID/repo@ID:event`). Discoverable only via
CloudTrail. Same lesson as terraform-eks-platform.

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
  - Required reviewers → add yourself
  - Deployment branches → allow only `main`

## 4. Local dev (optional)

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

`backend.hcl` is gitignored.

## 5. First run

```bash
git checkout -b test/first-plan
git add .
git commit -m "initial commit"
git push origin test/first-plan
# open PR - terraform-plan.yml comments the plan
# merge - terraform-apply.yml goes to Waiting on production approval
# approve in Actions UI - apply runs 3-6 min
```

## 6. Initialize the Vault cluster

After apply succeeds, wait ~90 seconds for `user_data` to install
Vault and start the service. **Don't init via an interactive SSM
shell** - the JSON with recovery keys and root token can be silently
truncated or wrapped by the terminal, and you'll only find out when
`jq` fails to parse the copy you saved. Init via `aws ssm
send-command`, write the JSON to a file on the node, then pull the
file back byte-for-byte:

```bash
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:vault-cluster,Values=vault-platform-demo" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

# init on the node, redirect output to /tmp/init.json
INIT_CMD_ID=$(aws ssm send-command \
  --instance-ids $INSTANCE_ID \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["export VAULT_ADDR=http://127.0.0.1:8200 && vault operator init -recovery-shares=5 -recovery-threshold=3 -format=json > /tmp/init.json"]' \
  --query 'Command.CommandId' --output text)

sleep 10
aws ssm get-command-invocation \
  --command-id $INIT_CMD_ID --instance-id $INSTANCE_ID \
  --query 'Status' --output text
# Expect: Success

# pull the file back
CAT_CMD_ID=$(aws ssm send-command \
  --instance-ids $INSTANCE_ID \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["cat /tmp/init.json"]' \
  --query 'Command.CommandId' --output text)

sleep 3
aws ssm get-command-invocation \
  --command-id $CAT_CMD_ID --instance-id $INSTANCE_ID \
  --query 'StandardOutputContent' --output text \
  > ~/vault-init-DO-NOT-COMMIT.json

# validate BEFORE saving anywhere
jq -r .root_token ~/vault-init-DO-NOT-COMMIT.json | head -c 20 ; echo
jq '.recovery_keys_b64 | length' ~/vault-init-DO-NOT-COMMIT.json
# Expect: hvs.CAES... and 5
```

Save to macOS Keychain:

```bash
security add-generic-password \
  -a "vault-platform-demo" \
  -s "terraform-vault-platform/init" \
  -w "$(cat ~/vault-init-DO-NOT-COMMIT.json)"
```

Read back:

```bash
# macOS 'security' encodes multi-line values in hex - always pipe
# through xxd -r -p when reading
security find-generic-password -s "terraform-vault-platform/init" -w \
  | xxd -r -p \
  | jq -r .root_token
```

Erase both copies:

```bash
shred -u ~/vault-init-DO-NOT-COMMIT.json

aws ssm send-command \
  --instance-ids $INSTANCE_ID \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["shred -u /tmp/init.json"]'
```

## 7. Verify the cluster

```bash
aws ssm start-session --target $INSTANCE_ID
```

On the node:

```bash
sudo -i
export VAULT_ADDR=http://127.0.0.1:8200
vault status                    # Initialized=true, Sealed=false, HA active
export VAULT_TOKEN=<paste root token from Keychain>
vault operator raft list-peers  # 3 peers, 1 leader, all Voter=true
```

## 8. Reach the Vault API from your laptop

```bash
aws ssm start-session \
  --target $INSTANCE_ID \
  --document-name AWS-StartPortForwardingSession \
  --parameters 'portNumber=["8200"],localPortNumber=["8200"]'

# in another terminal:
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<root-token>
vault status
```

## 9. Destroy

`Actions → terraform-destroy → Run workflow`, type `destroy` in the
input. Approve on the `production` environment. ~7 min.

The KMS key stays in a 7-day pending-deletion window. On the next
apply, Terraform creates a **new** KMS key and alias - no conflict
because destroy released the alias immediately.

## Cost profile

Full apply + 30 min live + destroy is about $0.30-0.50 on
on-demand pricing (3x t3.medium + NAT + NLB + KMS).

## Follow-ups

See the [README follow-ups section](../README.md#follow-ups-v2-scope-not-in-this-repo).
