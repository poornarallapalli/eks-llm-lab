output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --alias hub"
}

output "amp_workspace_id" {
  value = aws_prometheus_workspace.this.id
}

output "amp_remote_write_url" {
  value = local.amp_remote_write_url
}
