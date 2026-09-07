locals {
  # data.tfe_workspace_ids.data.ids is a map of workspace name => workspace id.
  workflowIds   = [for name, id in data.tfe_workspace_ids.data.ids : id]
  workflowNames = [for name, id in data.tfe_workspace_ids.data.ids : name]

  # project id => project name, used to name the per-project payload files and
  # to set a human-readable WorkflowGroup name in the payload.
  projectNames = { for p in data.tfe_projects.data.projects : p.id => p.name }

  # SG workflow-name (ResourceName) sanitization. Per the SG OpenAPI spec,
  # ResourceName must be 1-100 chars; SG's name convention is ^[-a-zA-Z0-9_]+$.
  # TFC workspace names already satisfy both, so for normal inputs this is a
  # no-op; the steps below defensively guarantee a valid, unique name and the
  # summary reports any workspace that was actually renamed.
  #   1. replace any disallowed character with "-"
  nameCleaned = { for name in local.workflowNames : name => replace(name, "/[^-a-zA-Z0-9_]/", "-") }
  #   2. enforce the 100-char maximum
  nameTruncated = { for name, cleaned in local.nameCleaned : name => length(cleaned) > 100 ? substr(cleaned, 0, 100) : cleaned }
  #   3. group originals by their sanitized name to detect collisions
  sanitizedGroups = { for name, san in local.nameTruncated : san => name... }
  #   4. disambiguate collisions with a short deterministic suffix (<=100 chars)
  resourceNames = {
    for name, san in local.nameTruncated :
    name => length(local.sanitizedGroups[san]) > 1 ? "${length(san) > 93 ? substr(san, 0, 93) : san}-${substr(md5(name), 0, 6)}" : san
  }

  # TFC never returns values for sensitive variables, so they cannot be
  # migrated. Record them per workspace so the summary can flag them.
  sensitiveVars = {
    for name, id in data.tfe_workspace_ids.data.ids :
    name => [for v in data.tfe_variables.data[id].variables : "${v.category}:${v.name}" if v.sensitive]
  }

  # Workspaces whose terraform_version is not a pinned semver (e.g. "latest" or
  # a constraint) and have no per-workspace override fall back to the default.
  versionFallbacks = {
    for name in local.workflowNames :
    name => data.tfe_workspace.data[name].terraform_version
    if !can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", data.tfe_workspace.data[name].terraform_version)) && try(var.workspaceOverrides[name].terraformVersion, null) == null
  }

  # Workspaces not using "remote" execution may not store their state in TFC, so
  # the API state export can come back empty; flag them in the summary.
  nonRemoteModes = {
    for name in local.workflowNames :
    name => data.tfe_workspace.data[name].execution_mode
    if data.tfe_workspace.data[name].execution_mode != "remote"
  }

  # Resolved SG VCS provider per workspace (override wins over the default).
  # Drives both the source config kind and which workspaces get VCS triggers.
  sourceKind = {
    for name in local.workflowNames :
    name => try(var.workspaceOverrides[name].sourceConfigDestKind, null) != null ? var.workspaceOverrides[name].sourceConfigDestKind : var.SGDefaultSourceConfigDestKind
  }

  # One SG workflow payload per workspace. Per-workspace overrides win over the
  # SGDefault* values; everything else is derived from the TFC workspace.
  workflowPayload = {
    for wsName, wsId in data.tfe_workspace_ids.data.ids : wsName => {
      CLIConfiguration = {
        "WorkflowGroup" : {
          # SG workflow group per TFC project: tfc-<project> (matches the group
          # the importer creates/targets and the per-project payload filename).
          "name" : "tfc-${local.projectFileSegment[data.tfe_workspace.data[wsName].project_id]}"
        },
        "TfStateFilePath" : "${abspath(path.root)}/../../${var.exportPath}/states/${data.tfe_workspace.data[wsName].name}.tfstate"
      }
      ResourceName = local.resourceNames[wsName]
      Description  = ""
      Tags         = data.tfe_workspace.data[wsName].tag_names
      EnvironmentVariables = concat(
        [for v in data.tfe_variables.data[wsId].variables :
          { "config" : { "textValue" : v.value, "varName" : v.name }, "kind" : "PLAIN_TEXT" }
        if v.category == "env" && v.sensitive == false],
        try(var.workspaceOverrides[wsName].extraEnvironmentVariables, [])
      )

      DeploymentPlatformConfig = try(var.workspaceOverrides[wsName].DeploymentPlatformConfig, null) != null ? var.workspaceOverrides[wsName].DeploymentPlatformConfig : var.SGDefaultDeploymentPlatformConfig
      RunnerConstraints        = try(var.workspaceOverrides[wsName].RunnerConstraints, null) != null ? var.workspaceOverrides[wsName].RunnerConstraints : { for k, v in var.SGDefaultRunnerConstraints : k => v if v != null }

      VCSConfig = {
        "iacVCSConfig" : {
          "useMarketplaceTemplate" : false,
          "customSource" : {
            "sourceConfigDestKind" : local.sourceKind[wsName]
            "config" : {
              "includeSubModule" : false,
              "ref" : length(data.tfe_workspace.data[wsName].vcs_repo) > 0 ? data.tfe_workspace.data[wsName].vcs_repo[0].branch : "",
              "isPrivate" : length(data.tfe_workspace.data[wsName].vcs_repo) > 0 ? length(data.tfe_workspace.data[wsName].vcs_repo[0].oauth_token_id) > 0 || length(data.tfe_workspace.data[wsName].vcs_repo[0].github_app_installation_id) > 0 : false,
              "auth" : length(data.tfe_workspace.data[wsName].vcs_repo) > 0 ? (length(data.tfe_workspace.data[wsName].vcs_repo[0].oauth_token_id) > 0 || length(data.tfe_workspace.data[wsName].vcs_repo[0].github_app_installation_id) > 0 ? (try(var.workspaceOverrides[wsName].vcsAuthIntegrationID, null) != null ? var.workspaceOverrides[wsName].vcsAuthIntegrationID : var.SGDefaultVCSAuthIntegrationID) : "") : "",
              "workingDir" : data.tfe_workspace.data[wsName].working_directory,
              "repo" : length(data.tfe_workspace.data[wsName].vcs_repo) > 0 ? format("%s/%s", try(var.workspaceOverrides[wsName].vcsRepoPrefix, null) != null ? var.workspaceOverrides[wsName].vcsRepoPrefix : var.SGDefaultIACVCSRepoPrefix, data.tfe_workspace.data[wsName].vcs_repo[0].identifier) : ""
            }
          }
        },
        "iacInputData" : {
          "schemaType" : "RAW_JSON",
          "data" : { for v in data.tfe_variables.data[wsId].variables : v.name => try(jsondecode(v.value), v.value) if v.category == "terraform" && v.sensitive == false }
        }
      }

      # VCS triggers, remapped 1:1 from the workspace's own TFC VCS settings.
      # Only emitted for VCS-backed workspaces on a provider SG can webhook
      # (GIT_OTHER has no webhook support); null otherwise. This block is NOT
      # accepted by the bulk workflow-create API — the importer applies it in a
      # second pass via POST .../wfs/<wf>/webhooks/vcs_triggers/ (see migrate.sh
      # cmd_triggers), which is what actually registers the repo webhook. Field
      # shape matches a real SG workflow + the landfast set_vcs_triggers call;
      # only the truly server-assigned fields (gh_webhook_url, *_hook_id,
      # github_app_installation_id) are omitted.
      VCSTriggers = try(var.workspaceOverrides[wsName].VCSTriggers, null) != null ? var.workspaceOverrides[wsName].VCSTriggers : (
        var.SGDefaultEnableVCSTriggers &&
        length(data.tfe_workspace.data[wsName].vcs_repo) > 0 &&
        contains(["GITHUB_COM", "GITLAB_COM", "BITBUCKET_ORG", "AZURE_DEVOPS"], local.sourceKind[wsName])
        ? {
          "type" : local.sourceKind[wsName],
          "tracked_branch" : data.tfe_workspace.data[wsName].vcs_repo[0].branch,
          "approval_pre_apply" : !data.tfe_workspace.data[wsName].auto_apply,
          "plan_only" : false,
          "gh_check" : true,
          "gl_pipeline" : true,
          "post_comments" : true,
          # TFC runs on every push to the tracked branch when VCS-connected.
          "push" : { "createWfRun" : { "enabled" : true } },
          # TFC speculative plans on PRs map to the PR-open/update triggers.
          "pull_request_opened" : { "createWfRun" : { "enabled" : data.tfe_workspace.data[wsName].speculative_enabled } },
          "pull_request_modified" : { "createWfRun" : { "enabled" : data.tfe_workspace.data[wsName].speculative_enabled } },
          "file_triggers_enabled" : data.tfe_workspace.data[wsName].file_triggers_enabled,
          # Prefer TFC's glob trigger_patterns; fall back to legacy
          # trigger_prefixes (prefix -> "<prefix>/*"); else, when file triggers
          # are on with a working dir, scope to that dir like TFC does.
          "file_trigger_patterns" : (
            try(length(data.tfe_workspace.data[wsName].trigger_patterns), 0) > 0 ? data.tfe_workspace.data[wsName].trigger_patterns :
            try(length(data.tfe_workspace.data[wsName].trigger_prefixes), 0) > 0 ? [for p in data.tfe_workspace.data[wsName].trigger_prefixes : "${p}/*"] :
            data.tfe_workspace.data[wsName].file_triggers_enabled && data.tfe_workspace.data[wsName].working_directory != "" ? ["${data.tfe_workspace.data[wsName].working_directory}/*"] : []
          )
        }
        : null
      )

      MiniSteps = {
        "wfChaining" : {
          "ERRORED" : [],
          "COMPLETED" : []
        },
        "notifications" : {
          "email" : {
            "ERRORED" : [],
            "COMPLETED" : [],
            "APPROVAL_REQUIRED" : [],
            "CANCELLED" : []
          }
        }
      }

      Approvers = try(var.workspaceOverrides[wsName].Approvers, null) != null ? var.workspaceOverrides[wsName].Approvers : (data.tfe_workspace.data[wsName].auto_apply ? [] : var.SGDefaultWfApprovers)

      TerraformConfig = {
        "managedTerraformState" : true,
        "terraformVersion" : (
          try(var.workspaceOverrides[wsName].terraformVersion, null) != null ? var.workspaceOverrides[wsName].terraformVersion :
          can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", data.tfe_workspace.data[wsName].terraform_version)) ? "TERRAFORM-${data.tfe_workspace.data[wsName].terraform_version}" : var.SGDefaultTerraformVersion
        ),
        "approvalPreApply" : !data.tfe_workspace.data[wsName].auto_apply
      }

      WfType        = "TERRAFORM"
      UserSchedules = []
    }
  }

  # Group payloads by TFC project so each project imports into its own SG
  # workflow group (the bulk import takes a single --workflow-group per file).
  workflowProject = { for wsName, wsId in data.tfe_workspace_ids.data.ids : wsName => data.tfe_workspace.data[wsName].project_id }
  projectsUsed    = toset(values(local.workflowProject))

  payloadByProject = {
    for pid in local.projectsUsed :
    pid => [for name, payload in local.workflowPayload : payload if local.workflowProject[name] == pid]
  }

  # project id => filesystem-safe segment for the per-project payload filename.
  projectFileSegment = {
    for pid in local.projectsUsed :
    pid => replace(lower(try(local.projectNames[pid], pid)), "/[^a-z0-9-]+/", "-")
  }

  # Machine-readable migration summary (also rendered to markdown).
  summary = {
    organization              = var.tfOrg
    workspaceCount            = length(local.workflowNames)
    projectWorkspaceCounts    = { for pid in local.projectsUsed : try(local.projectNames[pid], pid) => length(local.payloadByProject[pid]) }
    skippedSensitiveVars      = { for name, vars in local.sensitiveVars : name => vars if length(vars) > 0 }
    terraformVersionFallbacks = local.versionFallbacks
    nonRemoteExecutionModes   = local.nonRemoteModes
    renamedWorkspaces         = { for name in local.workflowNames : name => local.resourceNames[name] if local.resourceNames[name] != name }
    variableSetsReminder      = "TFC Variable Set variables are merged by the 'enrich' step (non-sensitive only). Sensitive set vars can't be read from the API — recreate them as SG secrets; see the enrich step output."
  }
}
