# TFC fixture for the live tests: two projects of workspaces and variable sets
# that cover the migrator's edge cases. Everything is created inside the
# fixture's own projects; nothing outside them is changed. Local state
# (gitignored). Auth: the tfe provider reads the `terraform login` file or
# TFE_TOKEN. `make live-seed` applies it and pushes a small state to every
# workspace (seed_state.sh).

terraform {
  required_version = ">= 1.6"
  required_providers {
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.68"
    }
  }
}

variable "tfc_org" {
  type = string
}

variable "prefix" {
  type        = string
  default     = "mig-test"
  description = "Name prefix of every project, workspace and variable set."
}

variable "vcs_repo" {
  type        = string
  description = "owner/repo the VCS-backed workspaces track."
}

variable "github_app_installation_id" {
  type        = string
  description = "The org's GitHub App installation (ghain-...), for the VCS-backed workspaces."
}

locals {
  p = var.prefix

  # name => settings. vcs = false makes a workspace without a repository.
  workspaces = {
    "${local.p}-basic" = { project = "a", version = "1.5.7", tags = ["mig-test", "team-a"], vcs = true }
    "${local.p}-dup"   = { project = "a", version = "1.9.8", tags = ["mig-test"], vcs = true }
    "${local.p}-novcs" = { project = "a", version = "~> 1.9.0", tags = ["mig-test"], vcs = false }
    "${local.p}_Under" = { project = "a", version = "1.5.7", tags = ["mig-test"], vcs = true }
    "${local.p}-b-one" = { project = "b", version = "1.5.7", tags = ["mig-test", "team-b"], vcs = true }
    "${local.p}-b-two" = { project = "b", version = "1.6.6", tags = ["mig-test", "team-b"], vcs = true }
    # Gets the 25-var set: more than one API page, and more env vars than
    # SG's update API accepts (20). Excluded from the default live scope.
    "${local.p}-big" = { project = "b", version = "1.5.7", tags = ["mig-test"], vcs = true }
  }

  # Workspace variables: [workspace, key, value, category, hcl, sensitive].
  ws_vars = [
    ["basic", "region", "eu-central-1", "terraform", false, false],
    ["basic", "subnets", "[\"a\", \"b\"]", "terraform", true, false],
    ["basic", "tags_map", "{ env = \"dev\", team = \"a\" }", "terraform", true, false],
    ["basic", "greeting", "hello $${name} and %%{if true}x%%{endif}", "terraform", false, false],
    ["basic", "LOG_LEVEL", "debug", "env", false, false],
    # Same name as env and as Terraform var, both sensitive; and a case pair.
    ["dup", "TOKEN", "env-token", "env", false, true],
    ["dup", "TOKEN", "tf-token", "terraform", false, true],
    ["dup", "db_password", "lower", "terraform", false, true],
    ["dup", "DB_PASSWORD", "upper", "env", false, true],
    ["dup", "instance_type", "t3.micro", "terraform", false, false],
    ["b-one", "x", "1", "terraform", false, false],
    ["b-two", "api_key", "k", "terraform", false, true],
    # With the 25-var set, more env vars than SG's update API accepts.
    ["big", "OWN_ENV", "own", "env", false, false],
    # The same sensitive name as in another workspace (a bare-name clash).
    ["b-two", "DB_PASSWORD", "other", "env", false, true],
  ]

  # Variable sets: name => { priority, projects, workspaces, vars = [key, value, category, sensitive] }.
  varsets = {
    "${local.p}-project-a" = {
      priority = false, projects = ["a"], workspaces = []
      vars = [
        ["region", "us-east-1", "terraform", false], # the workspace's own region wins
        ["SHARED_ENV", "from-project-set", "env", false],
        ["CROSS", "tf-val", "terraform", false],
      ]
    }
    "${local.p}-ws-shared" = {
      priority = false, projects = [], workspaces = ["basic", "b-one"]
      vars = [
        ["SHARED_SECRET", "s", "env", true],
        ["CROSS", "env-val", "env", false],
      ]
    }
    "${local.p}-priority" = {
      priority = true, projects = [], workspaces = ["dup"]
      vars = [
        ["instance_type", "t3.large", "terraform", false], # wins over the workspace's own
        ["PRIO_SECRET", "p", "env", true],
      ]
    }
  }

  # A set with more vars than one API page (20).
  big_vars = [for i in range(1, 26) : [format("BIG_%02d", i), tostring(i), "env", false]]

  set_vars = concat(
    flatten([for s, c in local.varsets : [for v in c.vars : { set = s, key = v[0], value = v[1], category = v[2], sensitive = v[3] }]]),
    [for v in local.big_vars : { set = "${local.p}-big", key = v[0], value = v[1], category = v[2], sensitive = v[3] }],
  )
}

resource "tfe_project" "this" {
  for_each     = toset(["a", "b"])
  organization = var.tfc_org
  name         = "${local.p}-${each.key}"
}

resource "tfe_workspace" "this" {
  for_each          = local.workspaces
  organization      = var.tfc_org
  name              = each.key
  project_id        = tfe_project.this[each.value.project].id
  tag_names         = each.value.tags
  queue_all_runs    = false
  auto_apply        = each.key == "${local.p}-basic"
  terraform_version = each.value.version

  dynamic "vcs_repo" {
    for_each = each.value.vcs ? [1] : []
    content {
      identifier                 = var.vcs_repo
      github_app_installation_id = var.github_app_installation_id
    }
  }
}

resource "tfe_variable" "ws" {
  for_each     = { for v in local.ws_vars : "${v[0]}|${v[3]}|${v[1]}" => v }
  workspace_id = tfe_workspace.this["${local.p}-${each.value[0]}"].id
  key          = each.value[1]
  value        = each.value[2]
  category     = each.value[3]
  hcl          = each.value[4]
  sensitive    = each.value[5]
}

resource "tfe_variable_set" "this" {
  for_each     = merge(local.varsets, { "${local.p}-big" = { priority = false, projects = [], workspaces = ["big"], vars = [] } })
  organization = var.tfc_org
  name         = each.key
  priority     = each.value.priority
}

resource "tfe_project_variable_set" "this" {
  for_each        = { for pair in flatten([for s, c in local.varsets : [for p in c.projects : { s = s, p = p }]]) : "${pair.s}|${pair.p}" => pair }
  project_id      = tfe_project.this[each.value.p].id
  variable_set_id = tfe_variable_set.this[each.value.s].id
}

resource "tfe_workspace_variable_set" "this" {
  for_each = {
    for pair in flatten([
      for s, c in merge(local.varsets, { "${local.p}-big" = { workspaces = ["big"] } }) : [for w in c.workspaces : { s = s, w = w }]
    ]) : "${pair.s}|${pair.w}" => pair
  }
  workspace_id    = tfe_workspace.this["${local.p}-${each.value.w}"].id
  variable_set_id = tfe_variable_set.this[each.value.s].id
}

resource "tfe_variable" "set" {
  for_each        = { for v in local.set_vars : "${v.set}|${v.category}|${v.key}" => v }
  variable_set_id = tfe_variable_set.this[each.value.set].id
  key             = each.value.key
  value           = each.value.value
  category        = each.value.category
  sensitive       = each.value.sensitive
}

output "workspace_ids" {
  value = { for k, w in tfe_workspace.this : k => w.id }
}
