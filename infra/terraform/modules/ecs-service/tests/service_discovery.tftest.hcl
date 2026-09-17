# No AWS credentials or API calls. Exercise the reusable ECS registry contract.
mock_provider "aws" {
  override_during = plan

  mock_data "aws_region" {
    defaults = { name = "il-central-1" }
  }

  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/test-role" }
  }
}

variables {
  name               = "mokaid-test-worker"
  cluster_arn        = "arn:aws:ecs:il-central-1:123456789012:cluster/mokaid-test"
  vpc_id             = "vpc-12345678"
  private_subnet_ids = ["subnet-12345678", "subnet-87654321"]
  container_image    = "123456789012.dkr.ecr.il-central-1.amazonaws.com/worker:test"
  container_port     = 8100
}

run "existing_services_keep_discovery_disabled" {
  command = plan

  assert {
    condition     = length(aws_ecs_service.this.service_registries) == 0
    error_message = "Cloud Map registration must remain opt-in for existing web/API/CRM services."
  }

  assert {
    condition     = !aws_ecs_service.this.network_configuration[0].assign_public_ip && length(aws_ecs_service.this.load_balancer) == 0
    error_message = "An unexposed worker must remain private and without a public load balancer."
  }
}

run "worker_uses_private_a_record_registry" {
  command = plan
  variables {
    service_registry = {
      registry_arn = "arn:aws:servicediscovery:il-central-1:123456789012:service/srv-0123456789abcdef"
    }
  }

  assert {
    condition     = length(aws_ecs_service.this.service_registries) == 1 && one(aws_ecs_service.this.service_registries).registry_arn == var.service_registry.registry_arn
    error_message = "The worker must register with exactly the provided Cloud Map service."
  }

  assert {
    condition     = aws_ecs_task_definition.this.network_mode == "awsvpc" && !aws_ecs_service.this.network_configuration[0].assign_public_ip && length(aws_ecs_service.this.load_balancer) == 0
    error_message = "A-record discovery requires awsvpc and must not expose the worker publicly."
  }

  assert {
    condition     = aws_ecs_service.this.deployment_circuit_breaker[0].enable && aws_ecs_service.this.deployment_circuit_breaker[0].rollback && aws_ecs_service.this.deployment_minimum_healthy_percent == 100
    error_message = "Adding a registry must preserve healthy rolling deployments and automatic rollback."
  }
}

run "invalid_registry_is_rejected" {
  command = plan
  variables {
    service_registry = { registry_arn = "https://worker.example.com" }
  }
  expect_failures = [var.service_registry]
}
