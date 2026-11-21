variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for secret names and IAM role name patterns (roles are <cluster>-external-secrets etc., clusters are llm-*)"
  type        = string
  default     = "llm-lab"
}

variable "cluster_name_pattern" {
  description = "IAM wildcard matching every spoke cluster name; used to scope access to roles created by the eks-spoke module"
  type        = string
  default     = "llm-*"
}

variable "secret_owner" {
  description = "Team that owns the secrets (tag; who gets paged, who rotates)"
  type        = string
  default     = "ml-platform"
}

variable "allow_force_destroy" {
  description = "Lab teardown only: allow terraform destroy to empty the model registry"
  type        = bool
  default     = false
}
