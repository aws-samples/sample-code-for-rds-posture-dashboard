variable "central_bus_arn" {
  description = "ARN of the central event bus (output event_bus_arn of the central configuration)."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:events:[a-z0-9-]+:[0-9]{12}:event-bus/.+$", var.central_bus_arn))
    error_message = "central_bus_arn must be an EventBridge event bus ARN."
  }
}

variable "stack_set_name" {
  description = "Name of the service-managed CloudFormation StackSet."
  type        = string
  default     = "rds-posture-member"
}

variable "organizational_unit_ids" {
  description = "Organizational unit IDs (or the root ID, r-xxxx) whose accounts receive the member stack."
  type        = list(string)

  validation {
    condition     = length(var.organizational_unit_ids) > 0
    error_message = "List at least one OU ID or the organization root ID."
  }
}

variable "regions" {
  description = "Regions to deploy the member stack in - us-east-1 for Trusted Advisor, the Security Hub delegated administrator's home Region, and every Region that hosts RDS (CloudTrail, Config and AWS Health events are Regional)."
  type        = list(string)
  default     = ["us-east-1"]
}

variable "seed_event_source" {
  description = "Extra source accepted by the forwarding rules (passed through to the member template)."
  type        = string
  default     = "rds-posture.seed"
}

variable "enable_security_hub_rule" {
  description = "Create the Security Hub forwarding rule in every stack instance. Set to false when the Security Hub delegated administrator account (whose home Region already carries every member's findings) runs its own member deployment, so the StackSet does not duplicate those events."
  type        = bool
  default     = true
}

variable "enable_health_rule" {
  description = "Create the AWS Health forwarding rule in every stack instance. Set to false when AWS Health organizational view is enabled and the management or delegated administrator account forwards events for the whole organization."
  type        = bool
  default     = true
}

variable "exclude_health_backup_events" {
  description = "Drop the backup-Region copy of each AWS Health event in every stack instance. Set to true when the deployed Regions include a backup Region (us-west-2 backs up every other Region; us-east-1 backs up us-west-2), so the dashboard counts each Health event once."
  type        = bool
  default     = false
}

variable "call_as" {
  description = "SELF when applying from the management account, DELEGATED_ADMIN from a CloudFormation delegated administrator."
  type        = string
  default     = "SELF"

  validation {
    condition     = contains(["SELF", "DELEGATED_ADMIN"], var.call_as)
    error_message = "call_as must be SELF or DELEGATED_ADMIN."
  }
}

variable "failure_tolerance_percentage" {
  description = "Percentage of accounts per Region that may fail before the operation stops."
  type        = number
  default     = 10
}

variable "max_concurrent_percentage" {
  description = "Percentage of accounts deployed to concurrently."
  type        = number
  default     = 25
}

variable "tags" {
  description = "Tags applied to the StackSet and propagated to its stacks."
  type        = map(string)
  default     = {}
}
