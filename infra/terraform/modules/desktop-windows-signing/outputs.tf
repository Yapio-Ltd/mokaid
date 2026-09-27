output "signing_role_arn" {
  description = "AWS role for the protected stable Windows signing job."
  value       = aws_iam_role.signer.arn
}

output "windows_signing_secret_arn" {
  description = "Metadata-only secret ARN; populate the update seed outside Terraform."
  value       = aws_secretsmanager_secret.updates.arn
}
