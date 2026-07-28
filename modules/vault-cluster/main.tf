terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.*-x86_64"]
  }
}

# --- KMS для auto-unseal ---
resource "aws_kms_key" "unseal" {
  description             = "${var.cluster_name} Vault auto-unseal"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = merge(var.tags, { Name = "${var.cluster_name}-unseal" })
}

resource "aws_kms_alias" "unseal" {
  name          = "alias/${var.cluster_name}-unseal"
  target_key_id = aws_kms_key.unseal.key_id
}

# --- IAM ---
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vault" {
  name               = "${var.cluster_name}-vault"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "vault" {
  statement {
    sid       = "AutoUnseal"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.unseal.arn]
  }
  statement {
    sid       = "AutoJoin"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "vault" {
  role   = aws_iam_role.vault.id
  policy = data.aws_iam_policy_document.vault.json
}

# SSM Session Manager - shell без SSH-ключей
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.vault.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "vault" {
  name = "${var.cluster_name}-vault"
  role = aws_iam_role.vault.name
}

# --- Security group ---
resource "aws_security_group" "vault" {
  name        = "${var.cluster_name}-vault"
  description = "Vault cluster"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "api_from_vpc" {
  security_group_id = aws_security_group.vault.id
  description       = "Vault API (8200) from VPC - covers NLB and internal clients"
  ip_protocol       = "tcp"
  from_port         = 8200
  to_port           = 8200
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_ingress_rule" "cluster_self" {
  security_group_id            = aws_security_group.vault.id
  description                  = "Raft cluster port between peers"
  ip_protocol                  = "tcp"
  from_port                    = 8201
  to_port                      = 8201
  referenced_security_group_id = aws_security_group.vault.id
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.vault.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Launch Template + ASG ---
locals {
  cluster_tag_key   = "vault-cluster"
  cluster_tag_value = var.cluster_name
}

resource "aws_launch_template" "vault" {
  name_prefix   = "${var.cluster_name}-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.vault.arn
  }

  vpc_security_group_ids = [aws_security_group.vault.id]

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tpl", {
    vault_version     = var.vault_version
    cluster_name      = var.cluster_name
    region            = var.region
    kms_key_id        = aws_kms_key.unseal.key_id
    cluster_tag_key   = local.cluster_tag_key
    cluster_tag_value = local.cluster_tag_value
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name                          = "${var.cluster_name}-vault"
      (local.cluster_tag_key)       = local.cluster_tag_value
    })
  }
}

resource "aws_autoscaling_group" "vault" {
  name                = "${var.cluster_name}-vault"
  vpc_zone_identifier = var.private_subnet_ids
  min_size            = 3
  max_size            = 5
  desired_capacity    = 3
  health_check_type   = "EC2"
  target_group_arns   = [aws_lb_target_group.vault.arn]

  launch_template {
    id      = aws_launch_template.vault.id
    version = "$Latest"
  }

  dynamic "tag" {
    for_each = merge(var.tags, {
      Name                    = "${var.cluster_name}-vault"
      (local.cluster_tag_key) = local.cluster_tag_value
    })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  instance_refresh {
    strategy = "Rolling"
    preferences { min_healthy_percentage = 66 }
  }
}

# --- Internal NLB ---
resource "aws_lb" "vault" {
  name               = substr("${var.cluster_name}-vault", 0, 32)
  internal           = true
  load_balancer_type = "network"
  subnets            = var.private_subnet_ids
  tags               = var.tags
}

resource "aws_lb_target_group" "vault" {
  name        = substr("${var.cluster_name}-vault", 0, 32)
  port        = 8200
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    protocol            = "HTTP"
    path                = "/v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200"
    port                = "8200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 10
    matcher             = "200,429"
  }

  tags = var.tags
}

resource "aws_lb_listener" "vault" {
  load_balancer_arn = aws_lb.vault.arn
  port              = 8200
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vault.arn
  }
}
