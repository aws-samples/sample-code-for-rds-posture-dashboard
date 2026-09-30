variable "bus_name" {
  description = "Name of the custom event bus that member accounts forward RDS events to."
  type        = string
  default     = "rds-posture-bus"
}

variable "allowed_org_ids" {
  description = <<-EOT
    AWS Organizations IDs (o-xxxxxxxxxx) whose member accounts may PutEvents to the bus. Leave empty
    for a single-account deployment; same-account access is always allowed.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for o in var.allowed_org_ids : can(regex("^o-[a-z0-9]{10,32}$", o))])
    error_message = "Every entry must be an AWS Organizations ID such as o-a1b2c3d4e5."
  }
}

variable "log_group_name" {
  description = "CloudWatch Logs group that stores the raw events."
  type        = string
  default     = "/rds-posture/events"
}

variable "log_retention_days" {
  description = "Retention (days) for the raw event log group; the default keeps one year. 0 keeps events forever."
  type        = number
  default     = 365

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "Use one of the retention periods CloudWatch Logs accepts (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653 or 0 for never expire)."
  }
}

variable "alarm_email" {
  description = "Optional e-mail address subscribed to the alerts topic (confirm the subscription e-mail)."
  type        = string
  default     = ""
}

variable "metric_statuses" {
  description = <<-EOT
    failed-only (default) publishes Security Hub metrics for FAILED findings only, which keeps the
    number of custom metrics - and the bill - low at organization scale. all also publishes PASSED,
    WARNING and NOT_AVAILABLE so you can chart pass/fail ratios.
  EOT
  type        = string
  default     = "failed-only"

  validation {
    condition     = contains(["failed-only", "all"], var.metric_statuses)
    error_message = "metric_statuses must be failed-only or all."
  }
}

variable "metric_namespace" {
  description = "CloudWatch namespace for the derived metrics."
  type        = string
  default     = "RDSPosture"
}

variable "seed_event_source" {
  description = <<-EOT
    Extra event source accepted by every rule. The harness uses it to seed the baseline from the
    current Security Hub / Trusted Advisor state and to inject test events (custom events may not use
    the reserved aws.* sources).
  EOT
  type        = string
  default     = "rds-posture.seed"
}

variable "dashboard_name" {
  description = "Name of the CloudWatch dashboard. Dashboard names are account-wide, so pick a distinct one per deployment."
  type        = string
  default     = "RDS-Posture"
}

variable "alerts_topic_kms_key_id" {
  description = <<-EOT
    Optional customer managed KMS key (ID, ARN or alias) for server-side encryption of the alerts
    topic. It must be a customer managed key whose key policy grants cloudwatch.amazonaws.com
    kms:GenerateDataKey* and kms:Decrypt, or the alarms cannot publish to the topic - the AWS
    managed alias/aws/sns key does not allow that, which is why the topic is unencrypted by default.
  EOT
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to every resource that supports them."
  type        = map(string)
  default     = {}
}
