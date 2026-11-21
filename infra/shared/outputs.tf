output "secret_arns" {
  value = { for k, s in aws_secretsmanager_secret.this : k => s.arn }
}

output "secrets_kms_key_arn" {
  value = aws_kms_key.secrets.arn
}

output "model_registry_bucket" {
  value = aws_s3_bucket.models.id
}
