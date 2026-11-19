variable "region" {
  type    = string
  default = "us-east-1"
}

variable "hub_name" {
  description = "Name of the management (hub) cluster"
  type        = string
  default     = "platform-hub"
}

variable "kubernetes_version" {
  type    = string
  default = "1.35"
}

variable "vpc_cidr" {
  description = "Hub VPC CIDR. Must not overlap any spoke VPC (llm-lab uses 10.0.0.0/16)."
  type        = string
  default     = "10.100.0.0/16"
}

variable "spoke_clusters" {
  description = <<-EOT
    Existing EKS clusters for the hub to manage. Key = EKS cluster name (also its VPC's Name tag,
    as created by ../../terraform). Labels land on the Argo CD cluster secret and drive which
    ApplicationSets deploy to which cluster.
  EOT
  type = map(object({
    labels = map(string)
  }))
  default = {
    "llm-lab" = {
      labels = {
        env = "dev"
        gpu = "true"
      }
    }
  }
}

variable "gitops_repo_url" {
  description = "HTTPS URL of YOUR Git repo containing this lab, e.g. https://github.com/<you>/eks-llm-lab.git"
  type        = string
}

variable "gitops_revision" {
  type    = string
  default = "main"
}

variable "gitops_path" {
  description = "Path to the gitops/ folder inside the repo"
  type        = string
  default     = "platform/gitops"
}

variable "gitops_repo_token" {
  description = "GitHub fine-grained token (read-only Contents) if the repo is private. Leave empty for a public repo."
  type        = string
  default     = ""
  sensitive   = true
}

variable "private_zone" {
  description = "Route 53 private hosted zone shared by hub and spokes (service discovery across VPCs)"
  type        = string
  default     = "platform.internal"
}

variable "argocd_chart_version" {
  type    = string
  default = "10.18.2" # Argo CD v3.6.x
}

variable "argocd_apps_chart_version" {
  type    = string
  default = "2.0.8"
}

variable "aws_lb_controller_version" {
  description = "Used to fetch the matching IAM policy document"
  type        = string
  default     = "v3.6.3"
}
