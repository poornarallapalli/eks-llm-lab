output "cluster_name" {
  value = module.spoke.cluster_name
}

output "artifacts_bucket" {
  value = module.spoke.artifacts_bucket
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region us-east-1 --name ${module.spoke.cluster_name} --alias dev"
}
