# Shared services: secrets, encryption keys, model registry.
# In a real organisation this is its own AWS account (security / shared-services),
# owned by the platform-security team, applied BEFORE any environment.
#   terraform init -backend-config="bucket=<state_bucket output>"
terraform {
  required_version = ">= 1.10"

  backend "s3" {
    key          = "shared/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "llm-lab", Stack = "shared", ManagedBy = "terraform" }
  }
}
