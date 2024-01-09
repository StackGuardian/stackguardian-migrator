data "aws_cloudformation_stack" "resource" {
  for_each = { for stack in local.stack_names : stack.Name => stack }

  name = each.value.Name
}
