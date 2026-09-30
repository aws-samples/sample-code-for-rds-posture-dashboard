# RDS posture - member configuration. Apply in every account and Region that must forward events
# (see the feed table in the README): forwards Trusted Advisor, Security Hub CSPM, CloudTrail
# (RDS API), AWS Config and AWS Health events about RDS resources from this account's default
# event bus to the central rds-posture bus.
#
# Functionally identical to templates/rds-posture-member.yaml. For an organization-wide rollout
# from Terraform, see ../member-stackset, which manages a service-managed CloudFormation StackSet
# of that template - EventBridge rules must exist in every member account, and a StackSet is the
# native way to fan them out.

data "aws_region" "current" {}

locals {
  region    = data.aws_region.current.region
  role_name = coalesce(var.forwarder_role_name, "rds-posture-forwarder-${local.region}")

  # Health pattern optionally drops the backup-Region copy of each event (detail.backupEvent).
  health_detail = merge(
    { service = ["RDS"] },
    var.exclude_health_backup_events ? { backupEvent = [{ exists = false }] } : {}
  )

  # Same five patterns as the central rules; every rule also accepts the seed source.
  # Security Hub and Health rules are optional: see the enable_* variable descriptions.
  all_rules = {
    trusted-advisor = {
      description = "Forward Trusted Advisor RDS / Aurora check item changes to the central bus"
      pattern = {
        source        = ["aws.trustedadvisor", var.seed_event_source]
        "detail-type" = ["Trusted Advisor Check Item Refresh Notification"]
        detail = {
          "check-name" = [{ wildcard = "*RDS*" }, { wildcard = "*Aurora*" }]
        }
      }
    }
    security-hub = {
      description = "Forward Security Hub RDS.* control findings to the central bus"
      pattern = {
        source        = ["aws.securityhub", var.seed_event_source]
        "detail-type" = ["Security Hub Findings - Imported"]
        detail = {
          findings = { Compliance = { SecurityControlId = [{ prefix = "RDS." }] } }
        }
      }
    }
    api-activity = {
      description = "Forward CloudTrail RDS API calls that change protection posture (deletion protection off, unprotected create, delete) to the central bus"
      pattern = {
        source        = ["aws.rds", var.seed_event_source]
        "detail-type" = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["rds.amazonaws.com"]
          "$or" = [
            {
              eventName         = ["ModifyDBInstance", "ModifyDBCluster"]
              requestParameters = { deletionProtection = [false] }
            },
            {
              eventName         = ["CreateDBInstance", "CreateDBCluster"]
              requestParameters = { deletionProtection = [false, { exists = false }] }
            },
            {
              eventName = ["DeleteDBInstance", "DeleteDBCluster"]
            },
          ]
        }
      }
    }
    config-compliance = {
      description = "Forward AWS Config compliance changes on RDS resources to the central bus"
      pattern = {
        source        = ["aws.config", var.seed_event_source]
        "detail-type" = ["Config Rules Compliance Change"]
        detail = {
          resourceType = ["AWS::RDS::DBInstance", "AWS::RDS::DBCluster"]
        }
      }
    }
    health = {
      description = "Forward AWS Health RDS events (planned lifecycle, scheduled changes) to the central bus"
      pattern = {
        source        = ["aws.health", var.seed_event_source]
        "detail-type" = ["AWS Health Event"]
        detail        = local.health_detail
      }
    }
  }

  rules = {
    for name, rule in local.all_rules : name => rule
    if(name != "security-hub" || var.enable_security_hub_rule) &&
    (name != "health" || var.enable_health_rule)
  }
}

# EventBridge requires an IAM role on every cross-account event bus target (since 2 March 2023).
# Scoping the role to the central bus ARN keeps SCPs and organization boundaries in force.
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "put_events" {
  statement {
    effect    = "Allow"
    actions   = ["events:PutEvents"]
    resources = [var.central_bus_arn]
  }
}

resource "aws_iam_role" "forwarder" {
  name               = local.role_name
  description        = "Lets EventBridge rules in this account put RDS posture events on the central bus."
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "put_events" {
  name   = "put-events-to-central-bus"
  role   = aws_iam_role.forwarder.id
  policy = data.aws_iam_policy_document.put_events.json
}

resource "aws_cloudwatch_event_rule" "forward" {
  for_each = local.rules

  name          = "rds-posture-fwd-${each.key}"
  description   = each.value.description
  state         = "ENABLED"
  event_pattern = jsonencode(each.value.pattern)
  tags          = var.tags
}

resource "aws_cloudwatch_event_target" "central_bus" {
  for_each = aws_cloudwatch_event_rule.forward

  rule      = each.value.name
  target_id = "central-bus"
  arn       = var.central_bus_arn
  role_arn  = aws_iam_role.forwarder.arn

  depends_on = [aws_iam_role_policy.put_events]
}
