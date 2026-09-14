locals {
  # Workspace selection. data.tfe_workspace_ids applies workspacenames and the
  # tag filters inside TFC (name => id). tfWorkspaceIgnoreNames and tfProjects
  # have no provider equivalent and are applied here, so everything below
  # iterates local.selectedWorkspaces rather than the data source.
  ignoreNameRegexes = [for p in var.tfWorkspaceIgnoreNames : "^${replace(replace(replace(p, ".", "\\."), "*", ".*"), "?", ".")}$"]
  excludedWorkspaces = sort([
    for name, id in data.tfe_workspace_ids.data.ids : name
    if anytrue([for r in local.ignoreNameRegexes : can(regex(r, name))])
  ])
  # Name filters applied; data.tfe_workspace is read for these, because the
  # project of a workspace is only known from there.
  namedWorkspaces = {
    for name, id in data.tfe_workspace_ids.data.ids : name => id if !contains(local.excludedWorkspaces, name)
  }
  # tfProjects entries are TFC project names or their slug (the payload file
  # segment); [] = every project.
  projectSelectors = [for p in var.tfProjects : replace(lower(p), "/[^a-z0-9-]+/", "-")]
  unknownProjects  = sort([for p in var.tfProjects : p if !contains(values(local.projectSlugs), replace(lower(p), "/[^a-z0-9-]+/", "-"))])
  selectedWorkspaces = {
    for name, id in local.namedWorkspaces : name => id
    if length(var.tfProjects) == 0 || contains(local.projectSelectors, try(local.projectSlugs[data.tfe_workspace.data[name].project_id], data.tfe_workspace.data[name].project_id))
  }
  workflowIds   = [for name, id in local.selectedWorkspaces : id]
  workflowNames = [for name, id in local.selectedWorkspaces : name]

  # project id => project name, used to name the per-project payload files and
  # to set a human-readable WorkflowGroup name in the payload; and its slug,
  # the filesystem-safe segment of the payload filename (sg-payload.<slug>.json).
  projectNames = { for p in data.tfe_projects.data.projects : p.id => p.name }
  projectSlugs = { for pid, name in local.projectNames : pid => replace(lower(name), "/[^a-z0-9-]+/", "-") }

  # TFC project per workspace: id, and the raw name (falls back to the id when
  # the project is not visible to the token).
  workflowProject   = { for name in local.workflowNames : name => data.tfe_workspace.data[name].project_id }
  workspaceProjects = { for name, pid in local.workflowProject : name => try(local.projectNames[pid], pid) }

  # Effective override per workspace: workspaceOverrides > projectOverrides (by
  # the workspace's project name) > null, where null means "the SGDefault*
  # value decides". Null attributes are dropped from each layer before merge()
  # - merge() does not skip them - and the all-null base makes every
  # local.effective[name].<field> safe to reference.
  effective = {
    for name in local.workflowNames :
    name => merge(
      { for f in local.overrideFieldNames : f => null },
      { for k, v in try(var.projectOverrides[local.workspaceProjects[name]], {}) : k => v if v != null },
      { for k, v in try(var.workspaceOverrides[name], {}) : k => v if v != null },
    )
  }

  # projectOverrides keys that name no project of the TFC org (typo guard).
  unknownProjectOverrides = sort([for k in keys(var.projectOverrides) : k if !contains(values(local.projectNames), k)])

  # Effective cloud connector per workflow, and the credential env variables it
  # makes redundant: the family (AWS/AZURE/GCP) is the prefix of the connector
  # kind, e.g. AZURE_OIDC -> AZURE. Picked via a tuple, not a conditional: an
  # AWS and an Azure DeploymentPlatformConfig have different config shapes.
  deploymentPlatformConfig = {
    for name in local.workflowNames :
    name => try([for c in [local.effective[name].DeploymentPlatformConfig, var.SGDefaultDeploymentPlatformConfig] : c if c != null][0], var.SGDefaultDeploymentPlatformConfig)
  }
  cloudPrefix       = { for name in local.workflowNames : name => try(split("_", local.deploymentPlatformConfig[name][0].kind)[0], null) }
  cloudAuthPatterns = { for name in local.workflowNames : name => var.stripCloudAuthVars ? try(var.cloudAuthVarPatterns[local.cloudPrefix[name]], []) : [] }

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

  # TFC-specific variables (TFC_*, TFE_* by default) are meaningless in SG and
  # are stripped; recorded per workspace so the summary can list them.
  strippedVars = {
    for name, id in local.selectedWorkspaces :
    name => [for v in data.tfe_variables.data[id].variables : "${v.category}:${v.name}"
    if anytrue([for p in var.ignoreVarPatterns : can(regex(p, v.name))])]
  }

  # Cloud credential env variables the workflow's SG connector replaces
  # (stripCloudAuthVars). Stripped whether sensitive or not: a sensitive one
  # must not become a placeholder secret that fights the connector either.
  strippedCloudAuthVars = {
    for name, id in local.selectedWorkspaces :
    name => [for v in data.tfe_variables.data[id].variables : "${v.category}:${v.name}"
      if v.category == "env"
      && !anytrue([for p in var.ignoreVarPatterns : can(regex(p, v.name))])
    && anytrue([for p in local.cloudAuthPatterns[name] : can(regex(p, v.name))])]
  }

  # TFC never returns values for sensitive variables, so they cannot be
  # migrated. Record them per workspace so the summary can flag them
  # (stripped variables excluded — nobody needs a secret stub for those).
  sensitiveVars = {
    for name, id in local.selectedWorkspaces :
    name => [for v in data.tfe_variables.data[id].variables : "${v.category}:${v.name}"
      if v.sensitive
      && !anytrue([for p in var.ignoreVarPatterns : can(regex(p, v.name))])
    && !(v.category == "env" && anytrue([for p in local.cloudAuthPatterns[name] : can(regex(p, v.name))]))]
  }

  # Workspaces whose terraform_version is not a pinned semver (e.g. "latest" or
  # a constraint) and have no per-workspace override fall back to the default
  # (SGDefaultTerraformVersion, or the org's execution preset when that is null).
  versionFallbacks = {
    for name in local.workflowNames :
    name => data.tfe_workspace.data[name].terraform_version
    if !can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", data.tfe_workspace.data[name].terraform_version)) && local.effective[name].terraformVersion == null
  }

  # Terraform version sent per workflow. An override is always sent as-is.
  # Otherwise "carry" keeps a pinned TFC semver (TERRAFORM-x.y.z) and falls back
  # to SGDefaultTerraformVersion for anything else; "preset" (or a null default)
  # yields null, and the key is then left out of the payload so StackGuardian
  # fills it from the org's execution preset at import time.
  tfVersion = {
    for name in local.workflowNames :
    name => (
      local.effective[name].terraformVersion != null ? local.effective[name].terraformVersion :
      var.SGTerraformVersionSource == "preset" ? null :
      can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", data.tfe_workspace.data[name].terraform_version)) ? "TERRAFORM-${data.tfe_workspace.data[name].terraform_version}" :
      var.SGDefaultTerraformVersion
    )
  }

  # Runner constraints sent per workflow: override, else the global default,
  # else null (key left out, the execution preset decides). Picked via a tuple
  # rather than a conditional: an override with "names" and a default without
  # it are different object types, which a conditional refuses to unify.
  runnerConstraints = {
    for name in local.workflowNames :
    name => try([for c in [
      local.effective[name].RunnerConstraints,
      var.SGDefaultRunnerConstraints == null ? null : { for k, v in var.SGDefaultRunnerConstraints : k => v if v != null }
    ] : c if c != null][0], null)
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
    name => local.effective[name].sourceConfigDestKind != null ? local.effective[name].sourceConfigDestKind : var.SGDefaultSourceConfigDestKind
  }

  # One SG workflow payload per workspace. Overrides (workspace, then project)
  # win over the SGDefault* values; everything else is derived from the TFC
  # workspace.
  workflowPayload = {
    for wsName, wsId in local.selectedWorkspaces : wsName => merge({
      CLIConfiguration = {
        "WorkflowGroup" : {
          # SG workflow group per TFC project: projectOverrides[<project>].workflowGroup,
          # else tfc-<project>. The importer reads it from here (reused when it
          # exists, created otherwise); the payload file is still named by project.
          "name" : local.workflowGroups[wsName]
        },
        "TfStateFilePath" : "${abspath(path.root)}/../../${var.exportPath}/states/${data.tfe_workspace.data[wsName].name}.tfstate"
      }
      ResourceName = local.resourceNames[wsName]
      Description  = ""
      Tags         = data.tfe_workspace.data[wsName].tag_names
      EnvironmentVariables = concat(
        [for v in data.tfe_variables.data[wsId].variables :
          { "config" : { "textValue" : v.value, "varName" : v.name }, "kind" : "PLAIN_TEXT" }
          if v.category == "env" && v.sensitive == false
          && !anytrue([for p in var.ignoreVarPatterns : can(regex(p, v.name))])
        && !anytrue([for p in local.cloudAuthPatterns[wsName] : can(regex(p, v.name))])],
        local.effective[wsName].extraEnvironmentVariables != null ? local.effective[wsName].extraEnvironmentVariables : []
      )

      DeploymentPlatformConfig = local.deploymentPlatformConfig[wsName]

      VCSConfig = {
        "iacVCSConfig" : {
          "useMarketplaceTemplate" : false,
          "customSource" : {
            "sourceConfigDestKind" : local.sourceKind[wsName]
            "config" : {
              "includeSubModule" : false,
              "ref" : length(data.tfe_workspace.data[wsName].vcs_repo) > 0 ? data.tfe_workspace.data[wsName].vcs_repo[0].branch : "",
              "isPrivate" : length(data.tfe_workspace.data[wsName].vcs_repo) > 0 ? length(data.tfe_workspace.data[wsName].vcs_repo[0].oauth_token_id) > 0 || length(data.tfe_workspace.data[wsName].vcs_repo[0].github_app_installation_id) > 0 : false,
              "auth" : length(data.tfe_workspace.data[wsName].vcs_repo) > 0 ? (length(data.tfe_workspace.data[wsName].vcs_repo[0].oauth_token_id) > 0 || length(data.tfe_workspace.data[wsName].vcs_repo[0].github_app_installation_id) > 0 ? (local.effective[wsName].vcsAuthIntegrationID != null ? local.effective[wsName].vcsAuthIntegrationID : var.SGDefaultVCSAuthIntegrationID) : "") : "",
              "workingDir" : data.tfe_workspace.data[wsName].working_directory,
              "repo" : length(data.tfe_workspace.data[wsName].vcs_repo) > 0 ? format("%s/%s", local.effective[wsName].vcsRepoPrefix != null ? local.effective[wsName].vcsRepoPrefix : var.SGDefaultIACVCSRepoPrefix, data.tfe_workspace.data[wsName].vcs_repo[0].identifier) : ""
            }
          }
        },
        "iacInputData" : {
          "schemaType" : "RAW_JSON",
          "data" : { for v in data.tfe_variables.data[wsId].variables : v.name => try(jsondecode(v.value), v.value) if v.category == "terraform" && v.sensitive == false && !anytrue([for p in var.ignoreVarPatterns : can(regex(p, v.name))]) }
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
      # github_app_installation_id) are omitted. An override replaces the remap
      # entirely; picked via a tuple because an override object rarely has the
      # exact attribute set of the derived one (a conditional would refuse).
      VCSTriggers = try([for c in [local.effective[wsName].VCSTriggers, (
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
      )] : c if c != null][0], null)

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

      Approvers = local.effective[wsName].Approvers != null ? local.effective[wsName].Approvers : (data.tfe_workspace.data[wsName].auto_apply ? [] : var.SGDefaultWfApprovers)

      # terraformVersion is omitted (not null) when the execution preset should
      # decide: the SG API only fills in keys that are absent from the payload.
      TerraformConfig = { for k, v in {
        "managedTerraformState" : true,
        "terraformVersion" : local.tfVersion[wsName],
        "approvalPreApply" : !data.tfe_workspace.data[wsName].auto_apply
      } : k => v if v != null }

      WfType        = "TERRAFORM"
      UserSchedules = []
      # RunnerConstraints likewise: present only when we have a value to send.
    }, { for k, v in { RunnerConstraints = local.runnerConstraints[wsName] } : k => v if v != null })
  }

  # Group payloads by TFC project so each project imports into its own SG
  # workflow group (the bulk import takes a single --workflow-group per file).
  projectsUsed = toset(values(local.workflowProject))

  payloadByProject = {
    for pid in local.projectsUsed :
    pid => [for name, payload in local.workflowPayload : payload if local.workflowProject[name] == pid]
  }

  # project id => filesystem-safe segment for the per-project payload filename.
  projectFileSegment = {
    for pid in local.projectsUsed :
    pid => try(local.projectSlugs[pid], replace(lower(pid), "/[^a-z0-9-]+/", "-"))
  }

  # SG workflow group per project: projectOverrides[<name>].workflowGroup, else
  # tfc-<segment>; and the same per workspace for the payload and the summary.
  projectGroups = {
    for pid in local.projectsUsed :
    pid => try(var.projectOverrides[try(local.projectNames[pid], pid)].workflowGroup, null) != null ? var.projectOverrides[try(local.projectNames[pid], pid)].workflowGroup : "tfc-${local.projectFileSegment[pid]}"
  }
  workflowGroups = { for name, pid in local.workflowProject : name => local.projectGroups[pid] }

  # Machine-readable migration summary (also rendered to markdown).
  summary = {
    organization   = var.tfOrg
    workspaceCount = length(local.workflowNames)
    # Workspaces matched by the TFC filters but dropped by tfWorkspaceIgnoreNames,
    # and the project selection ([] = all; unknownProjects = selectors matching none).
    excludedWorkspaces     = local.excludedWorkspaces
    tfWorkspaceIgnoreNames = var.tfWorkspaceIgnoreNames
    tfProjects             = var.tfProjects
    unknownProjects        = local.unknownProjects
    projectWorkspaceCounts = { for pid in local.projectsUsed : try(local.projectNames[pid], pid) => length(local.payloadByProject[pid]) }
    # Per project (raw TFC name): payload file segment, SG workflow group, size.
    projects = {
      for pid in local.projectsUsed :
      try(local.projectNames[pid], pid) => {
        segment        = local.projectFileSegment[pid]
        workflowGroup  = local.projectGroups[pid]
        workspaceCount = length(local.payloadByProject[pid])
      }
    }
    workspaceProjects       = local.workspaceProjects # ws => raw TFC project name
    workflowGroups          = local.workflowGroups    # ws => SG workflow group
    unknownProjectOverrides = local.unknownProjectOverrides
    skippedSensitiveVars    = { for name, vars in local.sensitiveVars : name => vars if length(vars) > 0 }
    strippedVars            = { for name, vars in local.strippedVars : name => vars if length(vars) > 0 }
    ignoreVarPatterns       = var.ignoreVarPatterns
    # Cloud credential env vars replaced by each workflow's connector.
    stripCloudAuthVars    = var.stripCloudAuthVars
    cloudAuthVarPatterns  = var.cloudAuthVarPatterns
    workspaceCloudKinds   = { for name in local.workflowNames : name => try(local.deploymentPlatformConfig[name][0].kind, null) }
    strippedCloudAuthVars = { for name, vars in local.strippedCloudAuthVars : name => vars if length(vars) > 0 }
    # Version policy, so the later phases can explain what each workflow runs.
    terraformVersionSource    = var.SGTerraformVersionSource
    terraformVersionDefault   = var.SGDefaultTerraformVersion # null = the execution preset decides
    runnerConstraintsSource   = var.SGDefaultRunnerConstraints == null ? "preset" : "config"
    tfcTerraformVersions      = { for name in local.workflowNames : name => data.tfe_workspace.data[name].terraform_version }
    terraformVersionFallbacks = var.SGTerraformVersionSource == "carry" ? local.versionFallbacks : {}
    nonRemoteExecutionModes   = local.nonRemoteModes
    renamedWorkspaces         = { for name in local.workflowNames : name => local.resourceNames[name] if local.resourceNames[name] != name }
    variableSetsReminder      = "TFC Variable Set variables are merged by the 'enrich' step (non-sensitive only). Sensitive set vars can't be read from the API — recreate them as SG secrets; see the enrich step output."
  }
}
