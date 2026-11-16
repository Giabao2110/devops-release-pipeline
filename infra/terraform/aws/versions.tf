terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # Remote state (S3 backend with lockfile) would go here for a team setup.
  # This lab keeps local state because it is never applied from CI.
}
