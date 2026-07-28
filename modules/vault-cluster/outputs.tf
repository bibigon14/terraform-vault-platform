output "asg_name" { value = aws_autoscaling_group.vault.name }
output "nlb_dns_name" { value = aws_lb.vault.dns_name }
output "kms_key_id" { value = aws_kms_key.unseal.key_id }
output "security_group_id" { value = aws_security_group.vault.id }
output "iam_role_arn" { value = aws_iam_role.vault.arn }
