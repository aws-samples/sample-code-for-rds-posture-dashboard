# The 12-widget dashboard, identical to the DashboardBody in templates/rds-posture-central.yaml.
# Tables show the latest known state per resource from the event stream; the "Who changed" table
# is the CloudTrail change feed; the metric widgets chart the RDSPosture and AWS/TrustedAdvisor
# namespaces; the alarm widget shows the two alarms.

locals {
  lg = aws_cloudwatch_log_group.events.name

  dashboard = {
    # Latest-state tables only see events inside the dashboard time range; Security Hub CSPM
    # change-triggered controls re-emit at most every ~24 h, so default to 7 days (see README).
    start          = "-PT168H"
    periodOverride = "inherit"
    widgets = [
      {
        type = "text", x = 0, y = 0, width = 24, height = 3
        properties = {
          markdown = "## RDS posture\nSources: Trusted Advisor check-item events, Security Hub CSPM RDS.* controls, CloudTrail RDS API activity (deletion protection off / unprotected create / delete), AWS Config compliance changes (customer-managed rules only), AWS Health RDS lifecycle events. Raw events in CloudWatch Logs `${local.lg}`; metrics in namespace `${var.metric_namespace}`. Tables show the latest known state per resource from the event stream (seed it once with the harness). The Security Hub detail table shows engine and engine version when ASFF resource details supply them; Security Hub and Config remain the authoritative current inventory."
        }
      },
      {
        type = "log", x = 0, y = 3, width = 12, height = 8
        properties = {
          title  = "Security Hub RDS controls FAILING (latest state per resource) - by control and account"
          region = local.region
          view   = "table"
          query  = "SOURCE '${local.lg}' | fields @timestamp, `detail.findings.0.Compliance.SecurityControlId` as control, `detail.findings.0.AwsAccountId` as acct, `detail.findings.0.Resources.0.Id` as resource, `detail.findings.0.Compliance.Status` as status | filter `detail-type` = \"Security Hub Findings - Imported\" | stats latest(status) as current by control, acct, resource | filter current = \"FAILED\" | stats count(*) as failing by control, acct | sort failing desc"
        }
      },
      {
        type = "log", x = 12, y = 3, width = 12, height = 8
        properties = {
          title  = "Trusted Advisor RDS items flagged WARN/ERROR (latest state per resource) - by check and account"
          region = local.region
          view   = "table"
          query  = "SOURCE '${local.lg}' | fields @timestamp, `detail.check-name` as check, `detail.status` as status, `detail.resource_id` as resource, `account` as acct | filter `detail-type` = \"Trusted Advisor Check Item Refresh Notification\" | stats latest(status) as current by check, acct, resource | filter current in [\"WARN\", \"ERROR\"] | stats count(*) as flagged by check, acct | sort flagged desc"
        }
      },
      {
        type = "log", x = 0, y = 11, width = 24, height = 8
        properties = {
          title  = "Failing RDS resources - Security Hub detail (latest state per resource and control)"
          region = local.region
          view   = "table"
          query  = "SOURCE '${local.lg}' | fields @timestamp, `detail.findings.0.Compliance.SecurityControlId` as control, `detail.findings.0.Title` as titleRaw, `detail.findings.0.Resources.0.Id` as resource, `detail.findings.0.AwsAccountId` as acct, `detail.findings.0.Resources.0.Region` as regionRaw, `detail.findings.0.Compliance.Status` as status, coalesce(`detail.findings.0.Resources.0.Details.AwsRdsDbInstance.Engine`, `detail.findings.0.Resources.0.Details.AwsRdsDbCluster.Engine`, `detail.findings.0.Resources.0.Details.AwsRdsDbSnapshot.Engine`, `detail.findings.0.Resources.0.Details.AwsRdsDbClusterSnapshot.Engine`) as engineRaw, coalesce(`detail.findings.0.Resources.0.Details.AwsRdsDbInstance.EngineVersion`, `detail.findings.0.Resources.0.Details.AwsRdsDbCluster.EngineVersion`, `detail.findings.0.Resources.0.Details.AwsRdsDbSnapshot.EngineVersion`, `detail.findings.0.Resources.0.Details.AwsRdsDbClusterSnapshot.EngineVersion`) as engineVersionRaw | filter `detail-type` = \"Security Hub Findings - Imported\" | stats latest(status) as current, latest(titleRaw) as title, latest(regionRaw) as region, latest(engineRaw) as engine, latest(engineVersionRaw) as engineVersion, latest(@timestamp) as lastSeen by control, acct, resource | filter current = \"FAILED\" | fields fromMillis(lastSeen) as lastSeenAt | display control, acct, resource, engine, engineVersion, current, title, region, lastSeenAt | sort control asc | limit 200"
        }
      },
      {
        type = "log", x = 0, y = 19, width = 24, height = 8
        properties = {
          title  = "Flagged RDS resources - Trusted Advisor detail (latest state per resource and check)"
          region = local.region
          view   = "table"
          query  = "SOURCE '${local.lg}' | fields @timestamp, `account` as acct, `detail.check-name` as check, `detail.status` as status, `detail.resource_id` as resource | filter `detail-type` = \"Trusted Advisor Check Item Refresh Notification\" | stats latest(status) as current, latest(@timestamp) as lastSeen by check, acct, resource | filter current in [\"WARN\", \"ERROR\"] | fields fromMillis(lastSeen) as lastSeenAt | sort check asc | limit 200"
        }
      },
      {
        type = "metric", x = 0, y = 27, width = 12, height = 6
        properties = {
          title   = "Security Hub RDS control findings imported per hour (FAILED, by control)"
          region  = local.region
          view    = "timeSeries"
          stacked = true
          period  = 3600
          stat    = "Sum"
          metrics = [[{ expression = "SEARCH('{${var.metric_namespace},ControlId,Status} MetricName=\"SecurityHubRdsFindings\" Status=\"FAILED\"', 'Sum', 3600)", id = "e1", region = local.region }]]
        }
      },
      {
        type = "metric", x = 12, y = 27, width = 12, height = 6
        properties = {
          title   = "Trusted Advisor RDS items flagged per hour (by check)"
          region  = local.region
          view    = "timeSeries"
          stacked = true
          period  = 3600
          stat    = "Sum"
          metrics = [[{ expression = "SEARCH('{${var.metric_namespace},CheckName,Status} MetricName=\"TrustedAdvisorRdsFlaggedItems\"', 'Sum', 3600)", id = "e2", region = local.region }]]
        }
      },
      {
        type = "metric", x = 0, y = 33, width = 12, height = 6
        properties = {
          title   = "Trusted Advisor native metrics - RDS checks with Yellow/Red resources (this account)"
          region  = local.region
          view    = "timeSeries"
          stacked = false
          period  = 300
          stat    = "Maximum"
          metrics = [
            [{ expression = "SEARCH('{AWS/TrustedAdvisor,CheckName} MetricName=\"YellowResources\" RDS', 'Maximum', 300)", id = "e3", region = local.region }],
            [{ expression = "SEARCH('{AWS/TrustedAdvisor,CheckName} MetricName=\"RedResources\" RDS', 'Maximum', 300)", id = "e4", region = local.region }],
          ]
        }
      },
      {
        type = "alarm", x = 12, y = 33, width = 12, height = 6
        properties = {
          title  = "Alarms"
          alarms = [aws_cloudwatch_metric_alarm.deletion_protection_disabled_api.arn, aws_cloudwatch_metric_alarm.deletion_protection_failed.arn]
        }
      },
      {
        type = "log", x = 0, y = 39, width = 24, height = 8
        properties = {
          title  = "Who changed RDS protection posture - deletion protection switched off, created unprotected, deleted (CloudTrail via EventBridge)"
          region = local.region
          view   = "table"
          query  = "SOURCE '${local.lg}' | fields @timestamp, `account` as acct, `region` as rgn, `detail.eventName` as api, `detail.userIdentity.arn` as who, `detail.sourceIPAddress` as ip, coalesce(`detail.requestParameters.dBInstanceIdentifier`, `detail.requestParameters.dBClusterIdentifier`) as db, `detail.requestParameters.deletionProtection` as deletionProtection, `detail.errorCode` as errorCode | filter `detail-type` = \"AWS API Call via CloudTrail\" | sort @timestamp desc | limit 100"
        }
      },
      {
        type = "log", x = 0, y = 47, width = 12, height = 8
        properties = {
          title  = "AWS Config compliance changes on RDS resources (recent)"
          region = local.region
          view   = "table"
          query  = "SOURCE '${local.lg}' | fields @timestamp, `account` as acct, `region` as rgn, `detail.configRuleName` as rule, `detail.resourceType` as type, `detail.resourceId` as resource, `detail.newEvaluationResult.complianceType` as compliance | filter `detail-type` = \"Config Rules Compliance Change\" | sort @timestamp desc | display @timestamp, acct, rgn, rule, type, resource, compliance | limit 100"
        }
      },
      {
        type = "log", x = 12, y = 47, width = 12, height = 8
        properties = {
          title  = "AWS Health RDS events - planned lifecycle / end of standard support / scheduled changes"
          region = local.region
          view   = "table"
          query  = "SOURCE '${local.lg}' | fields @timestamp, `detail.eventTypeCode` as eventType, `detail.eventTypeCategory` as category, `detail.startTime` as starts, `detail.affectedAccount` as affectedAcct, `detail.eventDescription.0.latestDescription` as description | filter `detail-type` = \"AWS Health Event\" | sort @timestamp desc | display @timestamp, eventType, category, starts, affectedAcct, description | limit 50"
        }
      },
    ]
  }
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.dashboard_name
  dashboard_body = jsonencode(local.dashboard)
}
