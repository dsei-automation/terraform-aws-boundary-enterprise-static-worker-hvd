# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

#------------------------------------------------------------------------------
# User Data (cloud-init) arguments
#------------------------------------------------------------------------------
locals {
  user_data_args = {

    # https://developer.hashicorp.com/boundary/docs/configuration/worker

    # boundary settings
    boundary_version         = var.boundary_version
    systemd_dir              = "/etc/systemd/system",
    boundary_dir_bin         = "/usr/bin",
    boundary_dir_config      = "/etc/boundary.d",
    boundary_dir_home        = "/opt/boundary",
    boundary_install_url     = format("https://releases.hashicorp.com/boundary/%s/boundary_%s_linux_amd64.zip", var.boundary_version, var.boundary_version),
    boundary_upstream_ips    = var.boundary_upstream
    boundary_upstream_port   = var.boundary_upstream_port
    hcp_boundary_cluster_id  = var.hcp_boundary_cluster_id
    worker_is_internal       = var.worker_is_internal
    worker_tags              = lower(replace(jsonencode(merge(var.common_tags, var.worker_tags)), ":", "="))
    enable_session_recording = var.enable_session_recording
    additional_package_names = join(" ", var.additional_package_names)

    # KMS settings
    worker_kms_id = var.kms_worker_arn != "" ? data.aws_kms_key.worker[0].id : ""
    kms_endpoint  = var.kms_endpoint
    aws_region    = data.aws_region.current.name
  }
}

#------------------------------------------------------------------------------
# Boundary Worker EC2 Instance
# ------------------------------------------------------------------------------
locals {
  // If an AMI ID is provided via `var.ec2_ami_id`, use it.
  // Otherwise, use the latest AMI for the specified OS distro via `var.ec2_os_distro`.
  ami_id_list = tolist([
    var.ec2_ami_id,
    join("", data.aws_ami.ubuntu.*.image_id),
    join("", data.aws_ami.rhel.*.image_id),
    join("", data.aws_ami.centos.*.image_id),
    join("", data.aws_ami.amzn2.*.image_id),
  ])
}


locals {
  worker_keys = [for i in range(var.ec2_instance_count) : format("%02d", i)]
  workers = {
    for idx, key in local.worker_keys :
    key => {
      index     = idx
      subnet_id = var.worker_subnet_ids[idx % length(var.worker_subnet_ids)]
    }
  }
}


resource "aws_instance" "worker" {
  for_each = local.workers

  ami                  = coalesce(local.ami_id_list...)
  instance_type        = var.ec2_instance_size
  key_name             = var.ec2_ssh_key_pair
  iam_instance_profile = aws_iam_instance_profile.boundary_ec2.name

  # Spread across the provided subnets
  subnet_id = each.value.subnet_id

  # Use Elastic IPs if the worker is not internal
  associate_public_ip_address = false

  # Reuse the existing cloud-init template and arguments
  user_data = base64encode(
    templatefile("${path.module}/templates/boundary_custom_data.sh.tpl", local.user_data_args)
  )

  root_block_device {
    volume_type = var.ebs_volume_type
    volume_size = var.ebs_volume_size
    throughput  = var.ebs_throughput
    iops        = var.ebs_iops
    encrypted   = var.ebs_is_encrypted
    kms_key_id  = var.ebs_is_encrypted == true && var.ebs_kms_key_arn != "" ? var.ebs_kms_key_arn : null
  }

  vpc_security_group_ids = [
    aws_security_group.ec2_allow_ingress.id,
    aws_security_group.ec2_allow_egress.id,
  ]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = merge(
    { Name = "${var.friendly_name_prefix}-boundary-worker-${each.key}" },
    { "Type" = "aws_instance" },
    { OS_Distro = var.ec2_os_distro },
    var.common_tags
  )
}

resource "aws_eip" "worker" {
  for_each = var.worker_is_internal ? {} : local.workers
  domain   = "vpc"
  instance = aws_instance.worker[each.key].id

  tags = merge(
    {
      Name       = "${var.friendly_name_prefix}-boundary-worker-eip-${each.key}"
      InstanceId = aws_instance.worker[each.key].id
      WorkerKey  = each.key
    },
    var.common_tags
  )
}

#------------------------------------------------------------------------------
# Security Groups
#------------------------------------------------------------------------------
resource "aws_security_group" "ec2_allow_ingress" {
  name   = "${var.friendly_name_prefix}-boundary-worker-ec2-allow-ingress"
  vpc_id = var.vpc_id
  tags   = merge({ "Name" = "${var.friendly_name_prefix}-boundary-worker-ec2-allow-ingress" }, var.common_tags)
}

resource "aws_security_group_rule" "ec2_allow_ingress_9202_cidr" {
  count = var.cidr_allow_ingress_boundary_9202 != null ? 1 : 0

  type        = "ingress"
  from_port   = 9202
  to_port     = 9202
  protocol    = "tcp"
  cidr_blocks = var.cidr_allow_ingress_boundary_9202
  description = "Allow TCP/9202 inbound to Boundary Worker EC2 instances from specified CIDR ranges for workers."

  security_group_id = aws_security_group.ec2_allow_ingress.id
}

resource "aws_security_group_rule" "ec2_allow_ingress_9202_sg" {
  for_each = toset(var.sg_allow_ingress_boundary_9202)

  type                     = "ingress"
  from_port                = 9202
  to_port                  = 9202
  protocol                 = "tcp"
  source_security_group_id = each.key
  description              = "Allow TCP/9202 inbound to Boundary Worker EC2 instances from specified Security Groups for ingress workers."

  security_group_id = aws_security_group.ec2_allow_ingress.id
}

resource "aws_security_group_rule" "ec2_allow_ingress_ssh" {
  count = length(var.cidr_allow_ingress_ec2_ssh) > 0 ? 1 : 0

  type        = "ingress"
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = var.cidr_allow_ingress_ec2_ssh
  description = "Allow TCP/22 (SSH) inbound to Boundary Worker EC2 instances from specified CIDR ranges."

  security_group_id = aws_security_group.ec2_allow_ingress.id
}

resource "aws_security_group" "ec2_allow_egress" {
  name   = "${var.friendly_name_prefix}-boundary-worker-ec2-allow-egress"
  vpc_id = var.vpc_id
  tags   = merge({ "Name" = "${var.friendly_name_prefix}-boundary-worker-ec2-allow-egress" }, var.common_tags)
}

resource "aws_security_group_rule" "ec2_allow_egress_all" {

  type        = "egress"
  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
  description = "Allow all traffic outbound from Boundary Worker EC2 instances."

  security_group_id = aws_security_group.ec2_allow_egress.id
}

# ------------------------------------------------------------------------------
# Debug rendered boundary custom_data script from template
# ------------------------------------------------------------------------------
# Uncomment this block to debug the rendered boundary custom_data script
# resource "local_file" "debug_custom_data" {
#   content  = templatefile("${path.module}/templates/boundary_custom_data.sh.tpl", local.custom_data_args)
#   filename = "${path.module}/debug/debug_boundary_custom_data.sh"
# }
