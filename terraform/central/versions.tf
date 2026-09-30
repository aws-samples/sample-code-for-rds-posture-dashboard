terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0, < 7.0.0"
    }
  }
}

# No provider block on purpose: this configuration works both as a root module (terraform apply in
# this directory, Region and credentials from AWS_REGION / AWS_PROFILE or the shared config) and as a
# child module called from your own root configuration, where you supply the provider.
