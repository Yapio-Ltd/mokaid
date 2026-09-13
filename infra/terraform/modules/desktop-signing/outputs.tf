output "signing_role_arn" {
  description = "Non-secret AWS role ARN for the protected desktop-signing-stable environment."
  value       = aws_iam_role.signer.arn
}

output "macos_signing_secret_arn" {
  description = "Existing secret identifier only; no secret version or private credential is exposed."
  value       = var.macos_signing_secret_arn
}
