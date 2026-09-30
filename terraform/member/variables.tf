variable "central_bus_arn" {
  description = "ARN of the central event bus (output event_bus_arn of the central configuration, or EventBusArn of the central stack)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:events:[a-z0-9-]+:[0-9]{12}:event-bus/.+$", var.central_bus_arn))
    error_message = "central_bus_arn must be an EventBridge event bus ARN, for example arn:aws:events:us-east-1:111122223333:event-bus/rds-posture-bus."
  }
}

variable "seed_event_source" {
  description = "Extra source accepted by the rules so seeded / test events can be injected with PutEvents."
  type        = string
  default     = "rds-posture.seed"
}

variable "enable_security_hub_rule" {
  description = "Create the Security Hub forwarding rule. Set to false everywhere except the Security Hub delegated administrator account when cross-Region aggregation is on - the administrator's home Region already carries every member account's findings, so rules in member accounts only duplicate them."
  type        = bool
  default     = true
}

variable "enable_health_rule" {
  description = "Create the AWS Health forwarding rule. Set to false in member accounts when AWS Health organizational view is enabled and the management or delegated administrator account forwards events for the whole organization."
  type        = bool
  default     = true
}

variable "exclude_health_backup_events" {
  description = "Drop the backup-Region copy of each AWS Health event (detail.backupEvent present). Set to true when the deployed Regions include a backup Region (us-west-2 backs up every other Region; us-east-1 backs up us-west-2) and the primary Region also runs this configuration, so the dashboard counts each Health event once. Leave false when the backup copy may be the only copy this account receives."
  type        = bool
  default     = false
}

variable "forwarder_role_name" {
  description = "Name of the IAM role EventBridge assumes to put events on the central bus. Defaults to rds-posture-forwarder-<region> (IAM is global, so the Region keeps one role per deployment)."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource that supports them."
  type        = map(string)
  default     = {}
}
