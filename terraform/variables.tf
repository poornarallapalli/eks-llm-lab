variable "region" {
  description = "AWS region. us-east-1 / us-west-2 have the best GPU (g5/g6/g6e) availability."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name. Also used as the Karpenter node IAM role name and discovery tag."
  type        = string
  default     = "llm-lab"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Check `aws eks describe-cluster-versions` for what's in standard support."
  type        = string
  default     = "1.35"
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version (no leading v). Check https://github.com/aws/karpenter-provider-aws/releases"
  type        = string
  default     = "1.15.2"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
