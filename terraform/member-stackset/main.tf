# RDS posture - organization rollout of the member stack from Terraform.
#
# The forwarding rules have to exist in every member account, and Terraform cannot create resources
# in accounts it has no provider for. The native answer is a service-managed CloudFormation StackSet,
# which deploys templates/rds-posture-member.yaml to whole organizational units and to accounts that
# join later. This configuration manages that StackSet from Terraform, so the rollout stays in the
# same toolchain as the central configuration. Apply it in each organization's management account
# (or a CloudFormation delegated administrator with call_as = "DELEGATED_ADMIN"), and list every
# organization ID in the central configuration's allowed_org_ids.
#
# This configuration passes terraform validate but has not been applied here: it needs an
# AWS Organizations management account with trusted access enabled for StackSets.

resource "aws_cloudformation_stack_set" "member" {
  name             = var.stack_set_name
  description      = "RDS posture - forwards RDS events from every member account to the central bus"
  permission_model = "SERVICE_MANAGED"
  call_as          = var.call_as
  capabilities     = ["CAPABILITY_NAMED_IAM"]
  template_body    = file("${path.module}/../../templates/rds-posture-member.yaml")
  tags             = var.tags

  parameters = {
    CentralBusArn             = var.central_bus_arn
    SeedEventSource           = var.seed_event_source
    EnableSecurityHubRule     = tostring(var.enable_security_hub_rule)
    EnableHealthRule          = tostring(var.enable_health_rule)
    ExcludeHealthBackupEvents = tostring(var.exclude_health_backup_events)
  }

  auto_deployment {
    enabled                          = true
    retain_stacks_on_account_removal = false
  }

  operation_preferences {
    failure_tolerance_percentage = var.failure_tolerance_percentage
    max_concurrent_percentage    = var.max_concurrent_percentage
    region_concurrency_type      = "PARALLEL"
  }

  # AWS manages the administration role for SERVICE_MANAGED StackSets; ignore the value it returns.
  lifecycle {
    ignore_changes = [administration_role_arn]
  }
}

# One instance resource per Region; each deploys to every listed OU.
resource "aws_cloudformation_stack_set_instance" "member" {
  for_each = toset(var.regions)

  stack_set_name            = aws_cloudformation_stack_set.member.name
  stack_set_instance_region = each.value
  call_as                   = var.call_as

  deployment_targets {
    organizational_unit_ids = var.organizational_unit_ids
  }

  operation_preferences {
    failure_tolerance_percentage = var.failure_tolerance_percentage
    max_concurrent_percentage    = var.max_concurrent_percentage
    region_concurrency_type      = "PARALLEL"
  }
}
