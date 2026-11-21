################################################################################
# HUB: Argo CD (manages every cluster from Git) + Grafana, and the central metrics
# store, which is Amazon Managed Service for Prometheus (AMP). Every cluster
# remote_writes to AMP with SigV4 via Pod Identity. No NLBs, DNS or VPC peering.
#
# This stack also owns all CROSS-CLUSTER wiring (it runs after the spokes exist):
#   - Argo CD identity chain + EKS Access Entries on each spoke
#   - Pod Identity associations on each spoke for Prometheus -> AMP
#   - Argo CD cluster secrets (labels + annotations = the "GitOps Bridge")
################################################################################

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name       = var.hub_name
  azs        = slice(data.aws_availability_zones.available.names, 0, 3)
  account_id = data.aws_caller_identity.current.account_id

  amp_query_url        = aws_prometheus_workspace.this.prometheus_endpoint # ends with "/"
  amp_remote_write_url = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/remote_write"

  tags = {
    Project   = "eks-llm-lab"
    ManagedBy = "terraform"
  }
}

################################################################################
# Hub VPC + EKS (fixed, small: no GPUs, no Karpenter)
################################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name                                     = local.name
  kubernetes_version                       = var.kubernetes_version
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
    platform = {
      ami_type       = "BOTTLEROCKET_x86_64"
      instance_types = ["m6i.large"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
    }
  }

  tags = local.tags
}

################################################################################
# Central metrics: Amazon Managed Service for Prometheus
################################################################################
resource "aws_prometheus_workspace" "this" {
  alias = "eks-llm-lab"
  tags  = local.tags
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

# Write-only role: used by the Prometheus in EVERY cluster (hub + spokes)
resource "aws_iam_role" "amp_ingest" {
  name               = "${local.name}-amp-ingest"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "amp_ingest" {
  name = "amp-remote-write"
  role = aws_iam_role.amp_ingest.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["aps:RemoteWrite"]
      Resource = aws_prometheus_workspace.this.arn
    }]
  })
}

# Read-only role: used by Grafana on the hub
resource "aws_iam_role" "amp_query" {
  name               = "${local.name}-amp-query"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "amp_query" {
  name = "amp-query"
  role = aws_iam_role.amp_query.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["aps:QueryMetrics", "aps:GetSeries", "aps:GetLabels", "aps:GetMetricMetadata"]
      Resource = aws_prometheus_workspace.this.arn
    }]
  })
}

# ServiceAccount names come from the kube-prometheus-stack chart (release name "kps")
locals {
  prometheus_sa = "kps-kube-prometheus-stack-prometheus"
  grafana_sa    = "kps-grafana"
}

resource "aws_eks_pod_identity_association" "amp_ingest" {
  for_each        = toset(concat([local.name], keys(var.spokes)))
  cluster_name    = each.key
  namespace       = "monitoring"
  service_account = local.prometheus_sa
  role_arn        = aws_iam_role.amp_ingest.arn
  depends_on      = [module.eks]
}

resource "aws_eks_pod_identity_association" "amp_query" {
  cluster_name    = module.eks.cluster_name
  namespace       = "monitoring"
  service_account = local.grafana_sa
  role_arn        = aws_iam_role.amp_query.arn
}

################################################################################
# Argo CD identity: management role (Pod Identity on the hub) -> per-spoke role
# -> EKS Access Entry on that spoke. No kubeconfigs or tokens stored anywhere.
################################################################################
resource "aws_iam_role" "argocd_management" {
  name = "${local.name}-argocd-management"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = {
          "aws:RequestTag/kubernetes-namespace" = ["argocd"]
          "aws:RequestTag/kubernetes-service-account" = [
            "argocd-server",
            "argocd-application-controller",
            "argocd-applicationset-controller",
          ]
        }
      }
    }]
  })
  tags = local.tags
}

resource "aws_eks_pod_identity_association" "argocd" {
  for_each        = toset(["argocd-server", "argocd-application-controller", "argocd-applicationset-controller"])
  cluster_name    = module.eks.cluster_name
  namespace       = "argocd"
  service_account = each.key
  role_arn        = aws_iam_role.argocd_management.arn
}

resource "aws_iam_role" "argocd_spoke" {
  for_each = var.spokes
  name     = "${local.name}-argocd-${each.key}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.argocd_management.arn }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "argocd_assume_spokes" {
  name = "assume-spoke-roles"
  role = aws_iam_role.argocd_management.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sts:AssumeRole", "sts:TagSession"]
      Resource = [for r in aws_iam_role.argocd_spoke : r.arn]
    }]
  })
}

resource "aws_eks_access_entry" "argocd_spoke" {
  for_each      = var.spokes
  cluster_name  = each.key
  principal_arn = aws_iam_role.argocd_spoke[each.key].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "argocd_spoke" {
  for_each      = var.spokes
  cluster_name  = each.key
  principal_arn = aws_iam_role.argocd_spoke[each.key].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.argocd_spoke]
}

data "aws_eks_cluster" "spoke" {
  for_each = var.spokes
  name     = each.key
}

################################################################################
# Argo CD, cluster secrets, root app
################################################################################
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  wait             = true

  values = [yamlencode({
    configs = {
      params = {
        "server.insecure" = true # UI reached via port-forward / SSH tunnel
      }
      repositories = {
        gitops = { url = var.gitops_repo_url, type = "git", name = "gitops" }
        kueue = {
          url       = "registry.k8s.io/kueue/charts"
          type      = "helm"
          name      = "kueue"
          enableOCI = "true"
        }
      }
    }
  })]

  depends_on = [module.eks, aws_eks_pod_identity_association.argocd]
}

locals {
  common_annotations = {
    aws_region           = var.region
    amp_remote_write_url = local.amp_remote_write_url
    amp_query_url        = local.amp_query_url
    model_registry       = "llm-lab-model-registry-${local.account_id}" # infra/shared
  }
}

resource "kubernetes_secret_v1" "cluster_hub" {
  metadata {
    name      = "cluster-${local.name}"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
      role                             = "hub"
      env                              = "hub"
    }
    annotations = merge(local.common_annotations, { cluster_name = local.name })
  }
  data = {
    name   = local.name
    server = "https://kubernetes.default.svc"
    config = jsonencode({ tlsClientConfig = { insecure = false } })
  }
  depends_on = [helm_release.argocd]
}

resource "kubernetes_secret_v1" "cluster_spoke" {
  for_each = var.spokes
  metadata {
    name      = "cluster-${each.key}"
    namespace = "argocd"
    labels = merge(each.value.labels, {
      "argocd.argoproj.io/secret-type" = "cluster"
      role                             = "spoke"
      env                              = each.value.env
    })
    annotations = merge(local.common_annotations, { cluster_name = each.key })
  }
  data = {
    name   = each.key
    server = data.aws_eks_cluster.spoke[each.key].endpoint
    config = jsonencode({
      awsAuthConfig = {
        clusterName = each.key
        roleARN     = aws_iam_role.argocd_spoke[each.key].arn
      }
      tlsClientConfig = {
        insecure = false
        caData   = data.aws_eks_cluster.spoke[each.key].certificate_authority[0].data
      }
    })
  }
  depends_on = [helm_release.argocd, aws_eks_access_policy_association.argocd_spoke]
}

resource "helm_release" "argocd_root" {
  name       = "argocd-root"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version

  values = [yamlencode({
    applications = {
      platform-root = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_revision
          path           = "gitops/bootstrap"
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "argocd"
        }
        syncPolicy = {
          automated = { prune = true, selfHeal = true }
        }
      }
    }
  })]

  depends_on = [kubernetes_secret_v1.cluster_hub, kubernetes_secret_v1.cluster_spoke]
}
