variable "region" {
  type    = string
  default = "us-east-1"
}

variable "hub_name" {
  type    = string
  default = "platform-hub"
}

variable "vpc_cidr" {
  type    = string
  default = "10.100.0.0/16"
}

variable "kubernetes_version" {
  type    = string
  default = "1.35"
}

variable "spokes" {
  description = <<-EOT
    Existing spoke clusters (created by infra/envs/*) for Argo CD to manage.
    Key = EKS cluster name. The labels drive which ApplicationSets target which
    cluster; "env" must match a folder in gitops/envs/.
  EOT
  type = map(object({
    env    = string
    labels = optional(map(string), {})
  }))
  default = {
    "llm-dev"     = { env = "dev", labels = { gpu = "true" } }
    "llm-staging" = { env = "staging", labels = { gpu = "true" } }
  }
}

variable "gitops_repo_url" {
  type    = string
  default = "https://github.com/poornarallapalli/eks-llm-lab.git"
}

variable "gitops_revision" {
  type    = string
  default = "main"
}

variable "argocd_chart_version" {
  type    = string
  default = "10.18.2" # Argo CD v3.6.x
}

variable "argocd_apps_chart_version" {
  type    = string
  default = "2.0.8"
}
