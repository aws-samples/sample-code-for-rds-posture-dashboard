output "forwarder_role_arn" {
  description = "IAM role EventBridge assumes to put events on the central bus."
  value       = aws_iam_role.forwarder.arn
}

output "rule_names" {
  description = "Forwarding rules created on this account's default event bus."
  value       = [for r in aws_cloudwatch_event_rule.forward : r.name]
}
