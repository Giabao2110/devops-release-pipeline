provider "aws" {
  region = var.region

  # offline_plan = true lets `terraform plan` run with no AWS account at all
  # (fake keys, no API validation). It is only for reviewing the plan; an
  # apply in this mode fails by design.
  access_key                  = var.offline_plan ? "offline-plan-only" : null
  secret_key                  = var.offline_plan ? "offline-plan-only" : null
  skip_credentials_validation = var.offline_plan
  skip_requesting_account_id  = var.offline_plan
  skip_metadata_api_check     = var.offline_plan
  skip_region_validation      = var.offline_plan

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Purpose   = "personal-devops-lab"
    }
  }
}
