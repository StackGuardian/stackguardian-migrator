"""
Transform scanned repository data into StackGuardian workflow payloads.

Takes the per-repo metadata (from VCS API + optional HCL parsing) and
produces a list of workflow JSON objects compatible with:
  - sg-cli workflow create --bulk
  - StackGuardian Import Workflows UI
"""

from typing import Any, Optional

from sg_git_scan.scanner import infer_terraform_version, infer_cloud_provider


def build_workflow(
    repo: dict[str, Any],
    project: dict[str, Any],
    *,
    # SG defaults (from config / CLI flags)
    wfgrp_name: str = "imported-workflows",
    deployment_platform_config: Optional[list[dict[str, Any]]] = None,
    vcs_auth_integration: str = "",
    source_config_dest_kind: str = "",
    runner_constraints: Optional[dict[str, Any]] = None,
    approvers: Optional[list[str]] = None,
    managed_terraform_state: bool = False,
    environment_variables: Optional[list[dict[str, Any]]] = None,
    tags: Optional[list[str]] = None,
) -> dict[str, Any]:
    """
    Build a single StackGuardian workflow payload from repo + project metadata.

    Parameters
    ----------
    repo : dict
        Repository metadata from VCS client (id, name, url, clone_url, ...).
    project : dict
        Terraform project metadata:
            path, tf_files, tfvars_files, providers, modules, variables,
            terraform_version, has_backend, backend_type, ...
    wfgrp_name : str
        Workflow group name in StackGuardian.
    deployment_platform_config : list
        Cloud connector config (kind + integrationId).
    vcs_auth_integration : str
        SG integration/secret path for VCS auth (e.g., /integrations/github_com).
    source_config_dest_kind : str
        VCS type: GITHUB_COM, GITLAB_COM, BITBUCKET_ORG, AZURE_DEVOPS, GIT_OTHER.
    runner_constraints : dict
        Runner config (shared vs private).
    approvers : list
        Email list for plan approvals.
    managed_terraform_state : bool
        Whether SG should manage the Terraform state.
    """
    providers = project.get("providers", [])
    tf_version = infer_terraform_version(project.get("terraform_version"))
    project_path = project.get("path", "")

    # --- Resource name ---
    # For monorepos (multiple projects), include the subdir in the name
    if project_path and project_path != ".":
        resource_name = f"{repo['name']}-{project_path.replace('/', '-')}"
    else:
        resource_name = repo["name"]

    # --- VCS config ---
    repo_url = repo.get("url", "")
    default_branch = repo.get("default_branch", "main")
    is_private = repo.get("is_private", True)

    # Auto-detect sourceConfigDestKind from provider field if not given
    if not source_config_dest_kind:
        provider_kind = repo.get("provider", "")
        kind_map = {
            "GITHUB_COM": "GITHUB_COM",
            "GITLAB_COM": "GITLAB_COM",
            "BITBUCKET_ORG": "BITBUCKET_ORG",
            "AZURE_DEVOPS": "AZURE_DEVOPS",
        }
        source_config_dest_kind = kind_map.get(provider_kind, "GIT_OTHER")

    # --- Deployment platform ---
    if not deployment_platform_config:
        inferred_cloud = infer_cloud_provider(providers)
        if inferred_cloud:
            deployment_platform_config = [{
                "kind": inferred_cloud,
                "config": {
                    "integrationId": f"/integrations/PLEASE_CONFIGURE",
                    "profileName": "default",
                },
            }]
        else:
            deployment_platform_config = []

    # --- Extra CLI args for tfvars ---
    tfvars_files = project.get("tfvars_files", [])
    extra_cli_args = ""
    if tfvars_files:
        # Use the first tfvars file found
        tfvars_path = tfvars_files[0]
        if project_path:
            extra_cli_args = f"-var-file={tfvars_path}"
        else:
            extra_cli_args = f"-var-file={tfvars_path}"

    # --- Tags ---
    wf_tags = list(tags or [])
    repo_topics = repo.get("topics", [])
    if repo_topics:
        wf_tags.extend(repo_topics)
    # add the iac type
    wf_tags.append("terraform")
    # deduplicate
    wf_tags = list(dict.fromkeys(wf_tags))

    # --- Build payload ---
    workflow: dict[str, Any] = {
        "ResourceName": resource_name,
        "Description": repo.get("description") or f"Workflow for {repo['full_name']}",
        "Tags": wf_tags,
        "EnvironmentVariables": environment_variables or [],
        "DeploymentPlatformConfig": deployment_platform_config,
        "WfType": "TERRAFORM",
        "TerraformConfig": {
            "managedTerraformState": managed_terraform_state,
            "terraformVersion": tf_version,
            "approvalPreApply": bool(approvers),
        },
        "VCSConfig": {
            "iacVCSConfig": {
                "useMarketplaceTemplate": False,
                "customSource": {
                    "sourceConfigDestKind": source_config_dest_kind,
                    "config": {
                        "repo": repo_url,
                        "ref": default_branch,
                        "isPrivate": is_private,
                        "auth": vcs_auth_integration if is_private else "",
                        "workingDir": project_path if project_path and project_path != "." else "",
                        "includeSubModule": False,
                    },
                },
            },
            "iacInputData": {
                "schemaType": "RAW_JSON",
                "data": {},
            },
        },
        "RunnerConstraints": runner_constraints or {"type": "shared"},
        "Approvers": approvers or [],
        "MiniSteps": {
            "wfChaining": {"ERRORED": [], "COMPLETED": []},
            "notifications": {
                "email": {
                    "ERRORED": [],
                    "COMPLETED": [],
                    "APPROVAL_REQUIRED": [],
                    "CANCELLED": [],
                },
            },
        },
        "UserSchedules": [],
        "CLIConfiguration": {
            "WorkflowGroup": {"name": wfgrp_name},
        },
    }

    # Add extra CLI args if tfvars detected
    if extra_cli_args:
        workflow["TerraformConfig"]["extraCLIArgs"] = extra_cli_args

    return workflow


def build_payload(
    repos_with_projects: list[tuple[dict[str, Any], list[dict[str, Any]]]],
    **kwargs,
) -> list[dict[str, Any]]:
    """
    Build the full sg-payload.json content from a list of (repo, projects) pairs.

    Each repo may have multiple Terraform projects (monorepo support).
    Returns a list of workflow dicts ready for JSON serialization.
    """
    workflows: list[dict[str, Any]] = []

    for repo, projects in repos_with_projects:
        for project in projects:
            wf = build_workflow(repo, project, **kwargs)
            workflows.append(wf)

    return workflows
