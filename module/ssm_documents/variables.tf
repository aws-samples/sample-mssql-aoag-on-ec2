# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# SSM Documents Module - Variables
###############################################################################

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "namespace" {
  description = "Namespace prefix for SSM document names to avoid collisions across deployments"
  type        = string
  default     = ""
}
