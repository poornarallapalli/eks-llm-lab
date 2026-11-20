locals {
  env = "staging"
}

# Same module, environment-specific inputs. Promoting an infrastructure change =
# a PR that makes the same change here after it was validated in the previous env.
module "spoke" {
  source = "../../modules/eks-spoke"
  providers = {
    aws          = aws
    aws.virginia = aws.virginia
  }

  cluster_name       = "llm-staging"
  env                = local.env
  vpc_cidr           = "10.20.0.0/16"
  kubernetes_version = "1.35"
  karpenter_version  = "1.15.2"
}
