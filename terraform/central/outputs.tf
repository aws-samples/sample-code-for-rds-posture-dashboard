output "event_bus_arn" {
  description = "Central bus ARN - pass as central_bus_arn to the member configuration / StackSet."
  value       = aws_cloudwatch_event_bus.this.arn
}

output "event_bus_name" {
  description = "Central bus name."
  value       = aws_cloudwatch_event_bus.this.name
}

output "event_log_group_name" {
  description = "CloudWatch Logs group holding the raw events."
  value       = aws_cloudwatch_log_group.events.name
}

output "alerts_topic_arn" {
  description = "SNS topic the two alarms notify."
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = aws_cloudwatch_dashboard.this.dashboard_name
}

output "dashboard_url" {
  description = "Console URL of the dashboard."
  value       = "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards:name=${aws_cloudwatch_dashboard.this.dashboard_name}"
}
