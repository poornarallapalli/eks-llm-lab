data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.virginia
}

locals {
  name = var.cluster_name
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Project   = "eks-llm-lab"
    ManagedBy = "terraform"
  }
}

################################################################################
# VPC: 3 AZs, private subnets for nodes, one NAT GW (cheap; not HA — fine for a lab)
################################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  # /20 private subnets = ~4k IPs each. VPC CNI gives every pod a real VPC IP,
  # so size subnets for pods, not just nodes.
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Karpenter's EC2NodeClass finds subnets by this tag
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags
}

################################################################################
# EKS cluster + a small managed node group for system pods and the Karpenter controller.
# GPU nodes are NOT defined here: Karpenter launches them on demand.
################################################################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  # Public endpoint so you can kubectl from your laptop. Lock this down with
  # endpoint_public_access_cidrs = ["<your-ip>/32"] if you like.
  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    system = {
      ami_type       = "BOTTLEROCKET_x86_64"
      instance_types = ["m6i.large"]

      min_size     = 2
      max_size     = 3
      desired_size = 2

      labels = {
        # The Karpenter controller is pinned here so it never runs on a node it manages
        "karpenter.sh/controller" = "true"
      }
    }
  }

  # The module's recommended rules allow node<->node on 1025-65535 (covers Istio xDS 15012,
  # ztunnel HBONE 15008, Calico Typha 5473) but only open specific webhook ports from the
  # control plane. Admission webhooks run in pods, so the API server must reach these:
  node_security_group_additional_rules = {
    ingress_cluster_15017_istio_webhook = {
      description                   = "Cluster API to node 15017/tcp Istio sidecar-injector + validation webhooks"
      protocol                      = "tcp"
      from_port                     = 15017
      to_port                       = 15017
      type                          = "ingress"
      source_cluster_security_group = true
    }
    ingress_cluster_5443_calico_apiserver = {
      description                   = "Cluster API to node 5443/tcp Calico API server (projectcalico.org/v3 APIs)"
      protocol                      = "tcp"
      from_port                     = 5443
      to_port                       = 5443
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  node_security_group_tags = merge(local.tags, {
    # Karpenter's EC2NodeClass finds the node security group by this tag
    "karpenter.sh/discovery" = local.name
  })

  tags = local.tags
}

################################################################################
# Karpenter: IAM (controller role via Pod Identity, node role), SQS interruption
# queue + EventBridge rules for Spot interruptions, then the Helm chart.
################################################################################
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  # Fixed name so EC2NodeClass can reference it as `role: llm-lab`
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = local.name

  create_pod_identity_association = true

  node_iam_role_additional_policies = {
    # Lets you `aws ssm start-session` onto GPU nodes for debugging
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

resource "helm_release" "karpenter" {
  namespace           = "kube-system"
  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = var.karpenter_version
  wait                = false

  values = [
    <<-EOT
    nodeSelector:
      karpenter.sh/controller: 'true'
    dnsPolicy: Default
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    webhook:
      enabled: false
    EOT
  ]

  depends_on = [module.eks]
}

################################################################################
# S3 bucket for training checkpoints / fine-tuned models, and a Pod Identity
# role so pods using ServiceAccount llm/trainer can read+write it. No static keys.
################################################################################
resource "aws_s3_bucket" "artifacts" {
  bucket_prefix = "${local.name}-artifacts-"
  force_destroy = true # lab only: lets `terraform destroy` delete a non-empty bucket
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "trainer" {
  name               = "${local.name}-trainer"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = local.tags
}

data "aws_iam_policy_document" "trainer_s3" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
}

resource "aws_iam_role_policy" "trainer_s3" {
  name   = "s3-artifacts"
  role   = aws_iam_role.trainer.id
  policy = data.aws_iam_policy_document.trainer_s3.json
}

resource "aws_eks_pod_identity_association" "trainer" {
  cluster_name    = module.eks.cluster_name
  namespace       = "llm"
  service_account = "trainer"
  role_arn        = aws_iam_role.trainer.arn
}
