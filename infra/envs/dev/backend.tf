# State for the dev environment only. The bucket comes from infra/bootstrap-state:
#   terraform init -backend-config="bucket=<state_bucket output>"
terraform {
  required_version = ">= 1.10"

  backend "s3" {
    key          = "envs/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true # S3-native state locking
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
}
