################################################################################
# HUB (management) cluster: Argo CD + central Prometheus/Grafana.
#
# Terraform only BOOTSTRAPS: network, cluster, IAM, Argo CD, and the Argo CD
# "cluster secrets" that describe every cluster (hub + spokes). Everything that
# runs *inside* clusters afterwards (LB controller, ExternalDNS, Prometheus,
# Kueue, Agent Sandbox, ...) is installed by Argo CD from Git.
#
# This is the "GitOps Bridge" pattern: Terraform writes the AWS facts Argo CD
# needs (VPC id, region, role names, URLs) as annotations on each cluster
# secret, and ApplicationSets template Helm values from those annotations.
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

  # Spokes send metrics here. ExternalDNS (on the hub) creates this record in the
  # private zone, pointing at an internal NLB in front of the central Prometheus.
  remote_write_url = "http://prometheus.${var.private_zone}:9090/api/v1/write"

  tags = {
    Project   = "eks-llm-lab-platform"
    ManagedBy = "terraform"
  }
}

################################################################################
# Hub VPC + EKS (small, fixed capacity: no GPUs, no Karpenter needed)
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

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 } # where the LB controller puts internal NLBs

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
    # Central Prometheus and Grafana keep their data on EBS (PVCs)
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    platform = {
      ami_type       = "BOTTLEROCKET_x86_64"
      instance_types = ["m6i.large"]
      min_size       = 3
      max_size       = 4
      desired_size   = 3 # one per AZ: Argo CD, Prometheus, Grafana, controllers
    }
  }

  tags = local.tags
}

################################################################################
# IAM for hub add-ons (all via EKS Pod Identity: no static keys, no OIDC trust per role)
################################################################################
data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# --- EBS CSI driver
resource "aws_iam_role" "ebs_csi" {
  name               = "${local.name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# --- AWS Load Balancer Controller (creates the internal NLB for remote-write)
data "http" "lbc_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${var.aws_lb_controller_version}/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "lbc" {
  name   = "${local.name}-aws-load-balancer-controller"
  policy = data.http.lbc_iam_policy.response_body
}

resource "aws_iam_role" "lbc" {
  name               = "${local.name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn
}

# --- ExternalDNS (writes prometheus.platform.internal into the private zone)
resource "aws_iam_role" "external_dns" {
  name               = "${local.name}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = local.tags
}

data "aws_iam_policy_document" "external_dns" {
  statement {
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [aws_route53_zone.platform.arn]
  }
  statement {
    actions   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResources"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "external_dns" {
  name   = "route53"
  role   = aws_iam_role.external_dns.id
  policy = data.aws_iam_policy_document.external_dns.json
}

resource "aws_eks_pod_identity_association" "external_dns" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-dns"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns.arn
}

################################################################################
# Networking hub <-> spokes: VPC peering + routes + one shared private DNS zone.
# (Peering is fine for a handful of VPCs. At fleet scale use Transit Gateway or
#  VPC Lattice: peering is non-transitive and grows as N^2.)
################################################################################
data "aws_vpc" "spoke" {
  for_each = var.spoke_clusters
  tags     = { Name = each.key } # set by ../../terraform (vpc module name = cluster name)
}

data "aws_route_tables" "spoke" {
  for_each = var.spoke_clusters
  vpc_id   = data.aws_vpc.spoke[each.key].id
}

resource "aws_vpc_peering_connection" "spoke" {
  for_each    = var.spoke_clusters
  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = data.aws_vpc.spoke[each.key].id
  auto_accept = true # same account + region

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
  requester {
    allow_remote_vpc_dns_resolution = true
  }

  tags = merge(local.tags, { Name = "${local.name}-to-${each.key}" })
}

# hub private route tables -> spoke CIDR
resource "aws_route" "hub_to_spoke" {
  for_each = {
    for pair in setproduct(keys(var.spoke_clusters), range(length(module.vpc.private_route_table_ids))) :
    "${pair[0]}/${pair[1]}" => { spoke = pair[0], idx = pair[1] }
  }
  route_table_id            = module.vpc.private_route_table_ids[each.value.idx]
  destination_cidr_block    = data.aws_vpc.spoke[each.value.spoke].cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.spoke[each.value.spoke].id
}

# every spoke route table -> hub CIDR
resource "aws_route" "spoke_to_hub" {
  for_each = merge([
    for spoke, rt in data.aws_route_tables.spoke : {
      for id in rt.ids : "${spoke}/${id}" => { spoke = spoke, rt_id = id }
    }
  ]...)
  route_table_id            = each.value.rt_id
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.spoke[each.value.spoke].id
}

resource "aws_route53_zone" "platform" {
  name    = var.private_zone
  comment = "Private service discovery shared by hub and spoke VPCs"

  vpc {
    vpc_id = module.vpc.vpc_id
  }

  dynamic "vpc" {
    for_each = var.spoke_clusters
    content {
      vpc_id = data.aws_vpc.spoke[vpc.key].id
    }
  }

  force_destroy = true
  tags          = local.tags
}

################################################################################
# Argo CD identity: one "management role" for Argo CD's pods (Pod Identity) that
# assumes a per-spoke role. Each spoke has an EKS Access Entry mapping that role
# to cluster-admin. No kubeconfigs or long-lived tokens are stored anywhere.
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

resource "aws_eks_pod_identity_association" "argocd" {
  for_each        = toset(["argocd-server", "argocd-application-controller", "argocd-applicationset-controller"])
  cluster_name    = module.eks.cluster_name
  namespace       = "argocd"
  service_account = each.key
  role_arn        = aws_iam_role.argocd_management.arn
}

resource "aws_iam_role" "argocd_spoke" {
  for_each = var.spoke_clusters
  name     = "${local.name}-argocd-${each.key}"
  # No permission policies: this role only exists to authenticate to the spoke's API.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${local.account_id}:role/${local.name}-argocd-management" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
  tags       = local.tags
  depends_on = [aws_iam_role.argocd_management]
}

resource "aws_eks_access_entry" "argocd_spoke" {
  for_each      = var.spoke_clusters
  cluster_name  = each.key
  principal_arn = aws_iam_role.argocd_spoke[each.key].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "argocd_spoke" {
  for_each      = var.spoke_clusters
  cluster_name  = each.key
  principal_arn = aws_iam_role.argocd_spoke[each.key].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.argocd_spoke]
}

data "aws_eks_cluster" "spoke" {
  for_each = var.spoke_clusters
  name     = each.key
}

################################################################################
# Argo CD itself (Helm), then the cluster secrets, then the root "app of apps".
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
        "server.insecure" = true # lab: we reach the UI via port-forward
      }
      repositories = merge(
        {
          gitops = merge(
            { url = var.gitops_repo_url, type = "git", name = "gitops" },
            var.gitops_repo_token == "" ? {} : { username = "git", password = var.gitops_repo_token }
          )
          # Kueue publishes its chart only as OCI
          kueue = {
            url       = "registry.k8s.io/kueue/charts"
            type      = "helm"
            name      = "kueue"
            enableOCI = "true"
          }
        }
      )
    }
  })]

  depends_on = [
    module.eks,
    aws_eks_pod_identity_association.argocd,
  ]
}

# The hub registers itself so ApplicationSets can target it by label (role=hub)
resource "kubernetes_secret_v1" "cluster_hub" {
  metadata {
    name      = "cluster-${local.name}"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
      role                             = "hub"
    }
    annotations = {
      cluster_name     = local.name
      aws_region       = var.region
      aws_vpc_id       = module.vpc.vpc_id
      private_zone     = var.private_zone
      remote_write_url = local.remote_write_url
      gitops_repo_url  = var.gitops_repo_url
      gitops_revision  = var.gitops_revision
      gitops_path      = var.gitops_path
    }
  }
  data = {
    name   = local.name
    server = "https://kubernetes.default.svc"
    config = jsonencode({ tlsClientConfig = { insecure = false } })
  }
  depends_on = [helm_release.argocd]
}

resource "kubernetes_secret_v1" "cluster_spoke" {
  for_each = var.spoke_clusters
  metadata {
    name      = "cluster-${each.key}"
    namespace = "argocd"
    labels = merge(each.value.labels, {
      "argocd.argoproj.io/secret-type" = "cluster"
      role                             = "spoke"
    })
    annotations = {
      cluster_name     = each.key
      aws_region       = var.region
      remote_write_url = local.remote_write_url
      gitops_repo_url  = var.gitops_repo_url
      gitops_revision  = var.gitops_revision
      gitops_path      = var.gitops_path
    }
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

# Root Application ("app of apps"): syncs every ApplicationSet in gitops/bootstrap.
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
          path           = "${var.gitops_path}/bootstrap"
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
