################################################################################
# A workload ("spoke") cluster: VPC + EKS + the Day-1 add-ons a cluster needs
# before Argo CD can manage it (VPC CNI, CoreDNS, kube-proxy, Pod Identity agent,
# Karpenter controller). Everything else is installed by Argo CD from Git.
################################################################################

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
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
  tags = merge(var.tags, {
    Project     = "eks-llm-lab"
    Environment = var.env
    ManagedBy   = "terraform"
  })
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.cluster_name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true # lab cost saver. Production: one NAT per AZ

  public_subnet_tags = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = var.cluster_name
  }

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name                                     = var.cluster_name
  kubernetes_version                       = var.kubernetes_version
  endpoint_public_access                   = true # Argo CD on the hub reaches the API here (IAM-authenticated)
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
      instance_types = var.system_instance_types
      min_size       = var.system_node_count
      max_size       = var.system_node_count + 1
      desired_size   = var.system_node_count
      labels = {
        "karpenter.sh/controller" = "true"
      }
    }
  }

  # Webhooks and aggregated APIs that run in pods must be reachable from the control plane
  node_security_group_additional_rules = {
    ingress_cluster_15017_istio_webhook = {
      description                   = "Cluster API to node 15017/tcp Istio injection + validation webhooks"
      protocol                      = "tcp"
      from_port                     = 15017
      to_port                       = 15017
      type                          = "ingress"
      source_cluster_security_group = true
    }
    ingress_cluster_5443_calico_apiserver = {
      description                   = "Cluster API to node 5443/tcp Calico API server"
      protocol                      = "tcp"
      from_port                     = 5443
      to_port                       = 5443
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  node_security_group_tags = merge(local.tags, {
    "karpenter.sh/discovery" = var.cluster_name
  })

  tags = local.tags
}

################################################################################
# Karpenter controller (Day-1: nodes for everything else depend on it).
# Its NodePools / EC2NodeClasses are NOT here: Argo CD manages them from Git.
################################################################################
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name                    = module.eks.cluster_name
  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = var.cluster_name
  create_pod_identity_association = true

  node_iam_role_additional_policies = {
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
# Per-environment S3 bucket for checkpoints / fine-tuned models + a Pod Identity
# role for ServiceAccount llm/trainer. Each environment can only reach its own bucket.
################################################################################
resource "aws_s3_bucket" "artifacts" {
  bucket_prefix = "${var.cluster_name}-artifacts-"
  force_destroy = true
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
  name               = "${var.cluster_name}-trainer"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "trainer_s3" {
  name = "s3-artifacts"
  role = aws_iam_role.trainer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket"], Resource = [aws_s3_bucket.artifacts.arn] },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = ["${aws_s3_bucket.artifacts.arn}/*"] },
    ]
  })
}

resource "aws_eks_pod_identity_association" "trainer" {
  cluster_name    = module.eks.cluster_name
  namespace       = "llm"
  service_account = "trainer"
  role_arn        = aws_iam_role.trainer.arn
}
