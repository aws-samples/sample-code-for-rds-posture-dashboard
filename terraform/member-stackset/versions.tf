terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0, < 7.0.0"
    }
  }
}

# No provider block on purpose. Apply with credentials for the organization's management account
# (or a CloudFormation delegated administrator, with call_as = "DELEGATED_ADMIN").
