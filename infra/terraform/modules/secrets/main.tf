variable "name_prefix" {
  type = string
}

variable "secrets" {
  description = "Map of secret name -> initial placeholder value. Real values are set out-of-band."
  type        = map(string)
  default     = {}
}

variable "parameters" {
  description = "Non-sensitive SSM parameters (name -> value)"
  type        = map(string)
  default     = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_secretsmanager_secret" "this" {
  for_each = var.secrets

  name_prefix = "${var.name_prefix}/${each.key}-"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "this" {
  for_each = var.secrets

  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = each.value

  lifecycle {
    # Real values are rotated manually / by ops, never overwritten by Terraform.
    ignore_changes = [secret_string]
  }
}

resource "aws_ssm_parameter" "this" {
  for_each = var.parameters

  name  = "/${var.name_prefix}/${each.key}"
  type  = "String"
  value = each.value
  tags  = var.tags
}

output "secret_arns" {
  value = { for name, secret in aws_secretsmanager_secret.this : name => secret.arn }
}

output "parameter_arns" {
  value = { for name, param in aws_ssm_parameter.this : name => param.arn }
}
