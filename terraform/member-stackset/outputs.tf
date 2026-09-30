output "stack_set_id" {
  description = "ID of the service-managed StackSet."
  value       = aws_cloudformation_stack_set.member.stack_set_id
}

output "stack_set_arn" {
  description = "ARN of the service-managed StackSet."
  value       = aws_cloudformation_stack_set.member.arn
}

output "regions" {
  description = "Regions with a stack instance for every listed OU."
  value       = sort([for i in aws_cloudformation_stack_set_instance.member : i.stack_set_instance_region])
}
