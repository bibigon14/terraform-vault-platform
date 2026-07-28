output "vault_nlb_dns_name" {
  value       = module.vault_cluster.nlb_dns_name
  description = "Internal NLB DNS - reach via SSM port-forward or from within VPC"
}

output "vault_asg_name" {
  value = module.vault_cluster.asg_name
}

output "vault_kms_key_id" {
  value = module.vault_cluster.kms_key_id
}

output "post_apply_hints" {
  value = <<-EOT
    # 1. Find a running instance
    aws ec2 describe-instances \
      --filters "Name=tag:vault-cluster,Values=${var.cluster_name}" "Name=instance-state-name,Values=running" \
      --query 'Reservations[].Instances[].InstanceId' --output text

    # 2. SSM into it
    aws ssm start-session --target <instance-id>

    # 3. On the node, init the cluster (ONE TIME, first node only):
    export VAULT_ADDR=http://127.0.0.1:8200
    vault operator init -recovery-shares=5 -recovery-threshold=3 -format=json > /tmp/init.json
    # save recovery keys + root token to password manager, then:
    shred -u /tmp/init.json

    # 4. Verify HA
    vault operator raft list-peers
  EOT
}
