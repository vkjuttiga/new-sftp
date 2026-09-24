terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # bucket/key/region are passed via -backend-config; each user gets its
  # own state file: s3://<state-bucket>/sftp-users/<user_name>.tfstate
  backend "s3" {
    encrypt      = true
    use_lockfile = true # S3 native locking, no DynamoDB table needed
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Purpose   = "sftp-user"
    }
  }
}
