resource "null_resource" "get_stack_names" {
  provisioner "local-exec" {
    command = <<-EOT
      aws cloudformation describe-stacks --query 'Stacks[*].{Name:StackName}' --output json > stack_names.json
    EOT
  }

  # Trigger the provisioner only once
  triggers = {
    always_run = "${timestamp()}"
  }
}


resource "aws_s3_object" "upload_templates" {
  for_each = data.aws_cloudformation_stack.resource

  bucket = var.s3Bucket
  key    = "${var.s3_path}/${each.key}.yaml"
  content = each.value.template_body
  depends_on = [ data.aws_cloudformation_stack.resource]
}

resource "local_file" "data" {
  content  = local.data
  filename = "${path.module}/../../${var.exportPath}/sg-payload-generated.json"
  provisioner "local-exec" {
    command = "mv ${path.module}/../../${var.exportPath}/sg-payload-generated.json ${path.module}/../../${var.exportPath}/sg-payload.json"
  }
  depends_on = [ aws_s3_object.upload_templates ]
}