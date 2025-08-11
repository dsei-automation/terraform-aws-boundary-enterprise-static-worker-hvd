# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

#------------------------------------------------------------------------------
# IAM
#------------------------------------------------------------------------------
output "boundary_worker_iam_role_name" {
  value       = try(aws_iam_role.boundary_ec2[0].name, null)
  description = "Name of the IAM role for Boundary Worker instances."
}

#------------------------------------------------------------------------------
# EC2 Instances
#------------------------------------------------------------------------------
output "workers" {
  value = {
    for k, inst in aws_instance.worker : k => {
      id         = inst.id
      name       = try(inst.tags["Name"], null)
      private_ip = inst.private_ip
      eip        = try(aws_eip.worker[k].public_ip, null)
    }
  }
  description = "Details of the Boundary Worker EC2 instances."
}
