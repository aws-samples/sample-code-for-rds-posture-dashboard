terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0, < 7.0.0"
    }
  }
}

# No provider block on purpose: apply this configuration directly (Region and credentials from
# AWS_REGION / AWS_PROFILE or the shared config) or call it as a child module with your own provider,
# once per account and Region that needs to forward events.
