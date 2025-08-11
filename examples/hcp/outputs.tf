# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

output "workers" {
  value       = module.boundary.workers
  description = "Details of the Boundary Worker EC2 instances."
}
