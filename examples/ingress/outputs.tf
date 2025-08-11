# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

output "workers" {
  value       = module.boundary.workers
  description = "Details of the Boundary Worker EC2 instances."
}

output "boundary_worker_iam_role_name" {
  value       = module.boundary.boundary_worker_iam_role_name
  description = "ARN of the IAM role for Boundary Worker instances."
}
