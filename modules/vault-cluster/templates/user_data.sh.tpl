#!/bin/bash
set -euxo pipefail

# --- Install Vault from HashiCorp repo ---
dnf install -y dnf-plugins-core
dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
dnf install -y vault-${vault_version}

# --- Instance-local addresses via IMDSv2 ---
TOKEN=$(curl -sS -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 300" \
  http://169.254.169.254/latest/api/token)
PRIVATE_IP=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
INSTANCE_ID=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

# --- Config ---
cat > /etc/vault.d/vault.hcl <<EOF
ui            = true
cluster_name  = "${cluster_name}"
disable_mlock = true

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = true
}

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "$INSTANCE_ID"

  retry_join {
    auto_join        = "provider=aws region=${region} tag_key=${cluster_tag_key} tag_value=${cluster_tag_value}"
    auto_join_scheme = "http"
  }
}

seal "awskms" {
  region     = "${region}"
  kms_key_id = "${kms_key_id}"
}

api_addr     = "http://$PRIVATE_IP:8200"
cluster_addr = "http://$PRIVATE_IP:8201"
EOF

mkdir -p /opt/vault/data
chown -R vault:vault /etc/vault.d /opt/vault
chmod 640 /etc/vault.d/vault.hcl

systemctl enable --now vault
