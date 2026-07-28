variable "cluster_name" {
  type        = string
  description = "Cluster name - drives resource naming and the vault-cluster tag used for Raft auto-join"
}

variable "region" { type = string }
variable "vpc_id" { type = string }

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR - allowed to reach the Vault API"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets for ASG and NLB (>= 2 AZs, 3 recommended)"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "vault_version" {
  type    = string
  default = "1.18.2-1"  # HashiCorp AL2023 package format: X.Y.Z-1
}

variable "tags" {
  type    = map(string)
  default = {}
}
