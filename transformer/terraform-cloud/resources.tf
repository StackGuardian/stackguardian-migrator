# One payload file per TFC project. Written directly (no -generated + mv dance)
# so re-applies always refresh the output.
resource "local_file" "data" {
  for_each = local.payloadByProject

  content  = jsonencode(each.value)
  filename = "${path.module}/../../${var.exportPath}/sg-payload.${local.projectFileSegment[each.key]}.json"
}

resource "local_file" "summary" {
  content  = jsonencode(local.summary)
  filename = "${path.module}/../../${var.exportPath}/migration-summary.json"
}

resource "local_file" "summaryMd" {
  content  = templatefile("${path.module}/summary.tmpl", { summary = local.summary })
  filename = "${path.module}/../../${var.exportPath}/migration-summary.md"
}

# Pull each workspace's current state directly from the TFC/TFE API — no
# `terraform init` or providers (avoids the plugin-cache concurrency issue and
# per-workspace provider downloads). The token is read at runtime from the
# `terraform login` credentials file or TFE_TOKEN, so it never enters TF state.
# Requires `curl` and `jq` on PATH (provided by the Docker image / orchestrator).
resource "null_resource" "exportState" {
  for_each = var.exportStateFiles ? data.tfe_workspace_ids.data.ids : {}

  # Idempotent by default (keyed by stable workspace name/id); forceStateRefresh
  # re-pulls every workspace.
  triggers = merge(
    { workspace = each.key, id = each.value },
    var.forceStateRefresh ? { refresh = timestamp() } : {}
  )

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    # SG_EXPORT is absolute and created in-command, so it works regardless of the
    # provisioner's working directory or resource ordering.
    environment = {
      SG_TFC_HOST = var.tfHostname
      SG_WS_ID    = each.value
      SG_WS_NAME  = each.key
      SG_EXPORT   = "${abspath(path.module)}/../../${var.exportPath}"
    }
    # Failure isolation: missing token / no-state / download error is recorded
    # in state-export-failures.log instead of aborting the whole apply.
    command = <<-EOT
      set -uo pipefail
      mkdir -p "$SG_EXPORT/states"
      creds="$HOME/.terraform.d/credentials.tfrc.json"
      token=""
      if [ -f "$creds" ] && command -v jq >/dev/null 2>&1; then
        token="$(jq -r --arg h "$SG_TFC_HOST" '.credentials[$h].token // empty' "$creds" 2>/dev/null || true)"
      fi
      [ -z "$token" ] && token="$${TFE_TOKEN:-}"
      if [ -z "$token" ]; then
        echo "$SG_WS_NAME: no TFC token (set TFE_TOKEN or run 'terraform login')" >> "$SG_EXPORT/state-export-failures.log"; exit 0
      fi
      url="$(curl -fsS -H "Authorization: Bearer $token" "https://$SG_TFC_HOST/api/v2/workspaces/$SG_WS_ID/current-state-version" | jq -r '.data.attributes."hosted-state-download-url" // empty' 2>/dev/null || true)"
      if [ -z "$url" ]; then
        echo "$SG_WS_NAME: no current state version" >> "$SG_EXPORT/state-export-failures.log"; exit 0
      fi
      curl -fsSL -H "Authorization: Bearer $token" "$url" -o "$SG_EXPORT/states/$SG_WS_NAME.tfstate" \
        || echo "$SG_WS_NAME: state download failed" >> "$SG_EXPORT/state-export-failures.log"
    EOT
  }
}
