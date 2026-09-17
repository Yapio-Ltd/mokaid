# Inspect the actual production networking composition without AWS calls.
mock_provider "aws" {
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}

mock_provider "random" {
  override_during = plan
}

override_module {
  target = module.vpc
  outputs = {
    vpc_id              = "vpc-12345678"
    private_subnet_ids  = ["subnet-12345678", "subnet-87654321"]
    public_subnet_ids   = ["subnet-11111111", "subnet-22222222"]
    public_subnet_cidrs = ["10.10.0.0/24", "10.10.1.0/24"]
  }
}

override_module {
  target  = module.api_service
  outputs = { security_group_id = "sg-11111111" }
}

override_module {
  target  = module.worker_service
  outputs = { security_group_id = "sg-22222222" }
}

variables {
  environment = "prod"
  aws_region  = "il-central-1"
}

run "coordinator_endpoint_is_private_and_api_only" {
  command = plan

  plan_options {
    target = [
      aws_service_discovery_private_dns_namespace.workers,
      aws_service_discovery_service.worker,
      aws_vpc_security_group_ingress_rule.worker_from_api,
    ]
  }

  assert {
    condition     = output.ai_worker_url == "http://ai-worker.mokaid-prod.internal:8100"
    error_message = "Production must publish the stable private coordinator endpoint."
  }

  assert {
    condition = (
      aws_service_discovery_private_dns_namespace.workers.vpc == "vpc-12345678" &&
      aws_service_discovery_service.worker.dns_config[0].routing_policy == "MULTIVALUE" &&
      one(aws_service_discovery_service.worker.dns_config[0].dns_records).type == "A" &&
      one(aws_service_discovery_service.worker.dns_config[0].dns_records).ttl == 10
    )
    error_message = "Worker DNS must use short-lived private IPv4 records registered by ECS."
  }

  assert {
    condition = (
      aws_vpc_security_group_ingress_rule.worker_from_api.security_group_id == "sg-22222222" &&
      aws_vpc_security_group_ingress_rule.worker_from_api.referenced_security_group_id == "sg-11111111" &&
      aws_vpc_security_group_ingress_rule.worker_from_api.ip_protocol == "tcp" &&
      aws_vpc_security_group_ingress_rule.worker_from_api.from_port == 8100 &&
      aws_vpc_security_group_ingress_rule.worker_from_api.to_port == 8100 &&
      aws_vpc_security_group_ingress_rule.worker_from_api.cidr_ipv4 == null &&
      aws_vpc_security_group_ingress_rule.worker_from_api.cidr_ipv6 == null
    )
    error_message = "Only API tasks may call tcp/8100; CIDR-based or public worker access is forbidden."
  }
}
