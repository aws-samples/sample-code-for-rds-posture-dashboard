# RDS posture - central configuration. Deploy once, in the monitoring account, in us-east-1.
# Receives Trusted Advisor, Security Hub CSPM, CloudTrail (RDS API), AWS Config and AWS Health
# events about Amazon RDS resources on a custom event bus, stores them in CloudWatch Logs,
# derives metrics, raises alarms and renders a CloudWatch dashboard. No Lambda, no external store.
#
# Functionally identical to templates/rds-posture-central.yaml - same names, event patterns,
# metric filters, alarms and dashboard - so either toolchain produces the same deployment.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  # EventBridge targets take the bare log-group ARN; the resource policy needs the ":*" form.
  log_group_arn = trimsuffix(aws_cloudwatch_log_group.events.arn, ":*")

  # Every rule also accepts the seed source so the harness can seed the baseline and inject test events.
  rules = {
    trusted-advisor = {
      description = "Trusted Advisor check item status changes for RDS / Aurora checks"
      pattern = {
        source        = ["aws.trustedadvisor", var.seed_event_source]
        "detail-type" = ["Trusted Advisor Check Item Refresh Notification"]
        detail = {
          "check-name" = [{ wildcard = "*RDS*" }, { wildcard = "*Aurora*" }]
        }
      }
    }
    security-hub = {
      description = "Security Hub CSPM findings for RDS.* controls (new and updated)"
      pattern = {
        source        = ["aws.securityhub", var.seed_event_source]
        "detail-type" = ["Security Hub Findings - Imported"]
        detail = {
          findings = { Compliance = { SecurityControlId = [{ prefix = "RDS." }] } }
        }
      }
    }
    api-activity = {
      description = "CloudTrail API activity that changes RDS protection posture - deletion protection switched off, instance/cluster created without it, or instance/cluster deleted (transition-based, near real time)."
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
      description = "AWS Config rule compliance changes on RDS instances and clusters. Only customer-managed Config rules (for example a conformance pack) emit these; Security Hub's service-linked rules do not."
      pattern = {
        source        = ["aws.config", var.seed_event_source]
        "detail-type" = ["Config Rules Compliance Change"]
        detail = {
          resourceType = ["AWS::RDS::DBInstance", "AWS::RDS::DBCluster"]
        }
      }
    }
    health = {
      description = "AWS Health events for RDS (planned lifecycle / end of standard support, scheduled changes)"
      pattern = {
        source        = ["aws.health", var.seed_event_source]
        "detail-type" = ["AWS Health Event"]
        detail = {
          service = ["RDS"]
        }
      }
    }
  }

  # Feed metric filters key on detail-type (not source) so seeded and test events count like real ones.
  # The two filters behind the alarms also require the genuine AWS source (aws.rds, aws.securityhub),
  # so a seeded or custom-source event can never raise an alarm; seeded events are counted on SeedEvents.
  securityhub_status_clause = var.metric_statuses == "all" ? "" : " && ($.detail.findings[0].Compliance.Status = \"FAILED\")"

  metric_filters = {
    ta-rds-flagged-items = {
      pattern    = "{ ($.detail-type = \"Trusted Advisor Check Item Refresh Notification\") && (($.detail.status = \"ERROR\") || ($.detail.status = \"WARN\")) }"
      metric     = "TrustedAdvisorRdsFlaggedItems"
      dimensions = { CheckName = "$.detail.check-name", Status = "$.detail.status" }
    }
    securityhub-rds-findings = {
      pattern    = "{ ($.detail-type = \"Security Hub Findings - Imported\") && ($.detail.findings[0].Compliance.SecurityControlId = \"RDS.*\")${local.securityhub_status_clause} }"
      metric     = "SecurityHubRdsFindings"
      dimensions = { ControlId = "$.detail.findings[0].Compliance.SecurityControlId", Status = "$.detail.findings[0].Compliance.Status" }
    }
    securityhub-rds-deletion-protection-failed = {
      pattern    = "{ ($.source = \"aws.securityhub\") && ($.detail-type = \"Security Hub Findings - Imported\") && ($.detail.findings[0].Compliance.Status = \"FAILED\") && (($.detail.findings[0].Compliance.SecurityControlId = \"RDS.7\") || ($.detail.findings[0].Compliance.SecurityControlId = \"RDS.8\")) }"
      metric     = "RdsDeletionProtectionFailedFindings"
      dimensions = null
    }
    api-rds-deletion-protection-disabled = {
      pattern    = "{ ($.source = \"aws.rds\") && ($.detail-type = \"AWS API Call via CloudTrail\") && ($.detail.eventSource = \"rds.amazonaws.com\") && (($.detail.eventName = \"ModifyDBInstance\") || ($.detail.eventName = \"ModifyDBCluster\")) && ($.detail.requestParameters.deletionProtection IS FALSE) }"
      metric     = "RdsDeletionProtectionDisabledApiCalls"
      dimensions = null
    }
    api-rds-created-without-deletion-protection = {
      pattern    = "{ ($.detail-type = \"AWS API Call via CloudTrail\") && ($.detail.eventSource = \"rds.amazonaws.com\") && (($.detail.eventName = \"CreateDBInstance\") || ($.detail.eventName = \"CreateDBCluster\")) && (($.detail.requestParameters.deletionProtection IS FALSE) || ($.detail.requestParameters.deletionProtection NOT EXISTS)) }"
      metric     = "RdsCreatedWithoutDeletionProtectionApiCalls"
      dimensions = null
    }
    api-rds-delete = {
      pattern    = "{ ($.detail-type = \"AWS API Call via CloudTrail\") && ($.detail.eventSource = \"rds.amazonaws.com\") && (($.detail.eventName = \"DeleteDBInstance\") || ($.detail.eventName = \"DeleteDBCluster\")) }"
      metric     = "RdsDeleteApiCalls"
      dimensions = null
    }
    config-rds-non-compliant = {
      pattern    = "{ ($.detail-type = \"Config Rules Compliance Change\") && ($.detail.newEvaluationResult.complianceType = \"NON_COMPLIANT\") }"
      metric     = "ConfigRdsNonCompliantChanges"
      dimensions = { ConfigRuleName = "$.detail.configRuleName" }
    }
    health-rds-events = {
      pattern    = "{ ($.detail-type = \"AWS Health Event\") && ($.detail.service = \"RDS\") }"
      metric     = "HealthRdsEvents"
      dimensions = { EventTypeCode = "$.detail.eventTypeCode" }
    }
    seed-events = {
      pattern    = "{ $.source = \"${var.seed_event_source}\" }"
      metric     = "SeedEvents"
      dimensions = null
    }
  }
}

# ---------------------------------------------------------------- event bus
resource "aws_cloudwatch_event_bus" "this" {
  name = var.bus_name
  tags = var.tags
}

# Same-account access is always allowed. Cross-account / cross-organization access: principals from
# every listed organization may put events; the sending account still needs its own IAM role on the
# forwarding rule (member configuration).
data "aws_iam_policy_document" "bus" {
  statement {
    sid    = "AllowSameAccountPutEvents"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.this.arn]
  }

  dynamic "statement" {
    for_each = length(var.allowed_org_ids) > 0 ? [1] : []
    content {
      sid    = "AllowOrganizationPutEvents"
      effect = "Allow"
      principals {
        type        = "*"
        identifiers = ["*"]
      }
      actions   = ["events:PutEvents"]
      resources = [aws_cloudwatch_event_bus.this.arn]
      condition {
        test     = "StringEquals"
        variable = "aws:PrincipalOrgID"
        values   = var.allowed_org_ids
      }
    }
  }
}

resource "aws_cloudwatch_event_bus_policy" "this" {
  event_bus_name = aws_cloudwatch_event_bus.this.name
  policy         = data.aws_iam_policy_document.bus.json
}

# ---------------------------------------------------------------- raw event store
resource "aws_cloudwatch_log_group" "events" {
  name              = var.log_group_name
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# aws:SourceAccount keeps another account's EventBridge from writing here through the service
# principal (confused-deputy protection).
data "aws_iam_policy_document" "logs" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
    }
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${local.log_group_arn}:*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "events" {
  policy_name     = "rds-posture-eventbridge-to-logs"
  policy_document = data.aws_iam_policy_document.logs.json
}

# ---------------------------------------------------------------- rules on the custom bus
resource "aws_cloudwatch_event_rule" "this" {
  for_each = local.rules

  name           = "rds-posture-${each.key}"
  description    = each.value.description
  event_bus_name = aws_cloudwatch_event_bus.this.name
  state          = "ENABLED"
  event_pattern  = jsonencode(each.value.pattern)
  tags           = var.tags
}

resource "aws_cloudwatch_event_target" "logs" {
  for_each = aws_cloudwatch_event_rule.this

  rule           = each.value.name
  event_bus_name = aws_cloudwatch_event_bus.this.name
  target_id      = "logs"
  arn            = local.log_group_arn

  depends_on = [aws_cloudwatch_log_resource_policy.events]
}

# ---------------------------------------------------------------- metrics derived from the log
resource "aws_cloudwatch_log_metric_filter" "this" {
  for_each = local.metric_filters

  name           = each.key
  log_group_name = aws_cloudwatch_log_group.events.name
  pattern        = each.value.pattern

  metric_transformation {
    name       = each.value.metric
    namespace  = var.metric_namespace
    value      = "1"
    unit       = "Count"
    dimensions = each.value.dimensions
  }
}

# ---------------------------------------------------------------- alerting
resource "aws_sns_topic" "alerts" {
  name              = "rds-posture-alerts"
  display_name      = "RDS posture alerts"
  kms_master_key_id = var.alerts_topic_kms_key_id != "" ? var.alerts_topic_kms_key_id : null
  tags              = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "deletion_protection_disabled_api" {
  alarm_name          = "rds-posture-deletion-protection-disabled-api"
  alarm_description   = "Someone switched deletion protection OFF on an RDS instance or cluster (CloudTrail ModifyDBInstance/ModifyDBCluster with deletionProtection=false). Transition-based - fires once per change."
  namespace           = var.metric_namespace
  metric_name         = "RdsDeletionProtectionDisabledApiCalls"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "deletion_protection_failed" {
  alarm_name          = "rds-posture-deletion-protection-failed"
  alarm_description   = "A Security Hub RDS.7/RDS.8 finding was imported as FAILED - an RDS instance or cluster is running without deletion protection. Re-fires each time Security Hub refreshes the finding (roughly every 12-24h) while the condition persists."
  namespace           = var.metric_namespace
  metric_name         = "RdsDeletionProtectionFailedFindings"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}
