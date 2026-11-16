variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "release-demo"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-southeast-1"
}

variable "offline_plan" {
  description = "Plan without AWS credentials (fake keys, no API calls). Never apply with this set."
  type        = bool
  default     = false
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "availability_zones" {
  description = "Two AZs for the public subnets."
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b"]
  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "Use at least two availability zones."
  }
}

variable "allowed_cidr" {
  description = "Only this CIDR may reach the app port (for example your public IP /32)."
  type        = string
  validation {
    condition     = can(cidrhost(var.allowed_cidr, 0)) && var.allowed_cidr != "0.0.0.0/0"
    error_message = "allowed_cidr must be a valid CIDR and must not be 0.0.0.0/0."
  }
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "ami_id" {
  description = "AMI to use. Empty = latest Amazon Linux 2023 from SSM (needs credentials)."
  type        = string
  default     = ""
}

variable "app_image" {
  description = "Container image the instance runs."
  type        = string
  default     = "ghcr.io/giabao2110/devops-release-pipeline:latest"
}

variable "bucket_suffix" {
  description = "Globally unique suffix for the artifact bucket name."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]{3,20}$", var.bucket_suffix))
    error_message = "bucket_suffix: 3-20 characters of a-z, 0-9 or '-'."
  }
}

variable "github_repository" {
  description = "owner/repo allowed to assume the CI publisher role through GitHub OIDC."
  type        = string
  default     = "Giabao2110/devops-release-pipeline"
}

variable "noncurrent_version_days" {
  description = "Days to keep overwritten artifact versions."
  type        = number
  default     = 30
}

variable "dev_build_days" {
  description = "Days to keep untagged CI builds under builds/."
  type        = number
  default     = 14
}
