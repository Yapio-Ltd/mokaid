variable "github_oidc_provider_arn" {
  description = "Existing account-wide GitHub OIDC provider, owned by the bootstrap stack."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn))
    error_message = "Pass an exact existing GitHub Actions OIDC provider ARN."
  }
}

variable "github_repository" {
  description = "Exact owner/repository trusted for the desktop-signing-stable environment; case is significant."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$", var.github_repository))
    error_message = "Use one exact owner/repository without wildcards, colons or ref claims."
  }
}

variable "tags" {
  description = "Additional non-secret tags; the module preserves its fixed identity and ownership tags."
  type        = map(string)
  default     = {}
  nullable    = false
}
