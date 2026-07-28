variable "region" {
  type    = string
  default = "us-west-2"
}

variable "cluster_name" {
  type    = string
  default = "vault-platform-demo"
}

variable "vpc_cidr" {
  type    = string
  default = "10.30.0.0/16" # non-overlapping with terraform-eks-platform (10.20.0.0/16)
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "vault_version" {
  type    = string
  default = "1.18.2-1"
}

variable "tags" {
  type    = map(string)
  default = {}
}
