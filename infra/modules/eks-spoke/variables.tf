variable "cluster_name" {
  description = "EKS cluster name. Also the Karpenter node role name and discovery tag value."
  type        = string
}

variable "env" {
  description = "Environment name (dev, staging, prod). Tagged on everything."
  type        = string
}

variable "vpc_cidr" {
  description = "Must be unique per environment so VPCs can be connected later without overlap"
  type        = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.35"
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version (no leading v)"
  type        = string
  default     = "1.15.2"
}

variable "system_instance_types" {
  type    = list(string)
  default = ["m6i.large"]
}

variable "system_node_count" {
  type    = number
  default = 2
}

variable "tags" {
  type    = map(string)
  default = {}
}
