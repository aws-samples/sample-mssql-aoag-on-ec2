# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  # Prefix for SSM document names - allows multiple deployments in same region
  name_prefix = var.namespace != "" ? "${var.namespace}_" : ""
}
