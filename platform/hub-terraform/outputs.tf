output "configure_kubectl_hub" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --alias hub"
}

output "argocd_admin_password_cmd" {
  value = "kubectl --context hub -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}

output "remote_write_url" {
  value = local.remote_write_url
}

output "spoke_peering_connections" {
  value = { for k, v in aws_vpc_peering_connection.spoke : k => v.id }
}
