resource "local_file" "data" {
  content  = local.data
  filename = "${path.module}/../../${var.exportPath}/sg-payload.json"
}
data "archive_file" "data" {
  depends_on = [ local_file.data,local_file.generateTempTfFiles , null_resource.deleteTempTfFiles, null_resource.exportStateFiles ]
  type        = "zip"
  source_dir = "${path.module}/../../${var.exportPath}"
  output_path = "${path.module}/../../zip/${var.exportPath}.zip"
}
resource "local_file" "generateTempTfFiles" {
  for_each = var.stateExport ? toset(local.workflowNames) : []

  content  = templatefile("${path.module}/workspace.tmpl", { tfOrg = var.tfOrg, workspace = each.key })
  filename = "${path.module}/../../${var.exportPath}/tfDir/${each.key}/main.tf"
}

resource "null_resource" "exportStateFiles" {
  triggers = {
     value = var.tfOrg,
     export = var.exportPath
  }
  depends_on = [local_file.generateTempTfFiles]
  for_each   = var.stateExport ? toset(local.workflowNames) : []

  provisioner "local-exec" {
    command     = "mkdir -p ../../states && rm -rf .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup && terraform init -input=false && terraform state pull > ../../states/'${each.key}.tfstate'"
    working_dir = "${path.module}/../../${var.exportPath}/tfDir/${each.key}"
  }
}

resource "null_resource" "deleteTempTfFiles" {
  count      = var.stateExport ? 1 : 0
  depends_on = [null_resource.exportStateFiles]

  provisioner "local-exec" {
    command     = "rm -rf tfDir"
    working_dir = "${path.module}/../../${var.exportPath}/"
  }
}