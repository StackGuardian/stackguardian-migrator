resource "local_file" "data" {
  content  = local.data
  filename = "${path.module}/../../${var.exportPath}/sg-payload.json"
}

resource "local_file" "generateTempTfFiles" {
  for_each = var.stateExport ? toset(local.workflowNames) : []

  content  = templatefile("${path.module}/workspace.tmpl", { tfOrg = var.tfOrg, workspace = each.key })
  filename = "${path.module}/../../${var.exportPath}/tfDir/${each.key}/main.tf"
}

resource "null_resource" "exportStateFiles" {
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