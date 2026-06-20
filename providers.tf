# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Default (unaliased) provider — used by resources not explicitly assigned to an alias
provider "aws" {
  region = var.aws_region_primary
}

provider "aws" {
  alias  = "site"
  region = var.aws_region_primary
}

provider "aws" {
  alias  = "drsite"
  region = var.aws_region_dr
}
