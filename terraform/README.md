# Terraform configurations

The Terraform configurations in this directory are functionally identical to the CloudFormation
templates in `templates/`: same resource names, event patterns, metric filters, alarms and
dashboard. Pick whichever toolchain your organization standardizes on; everything else in the
repository (harness sub-commands, fixtures, docs) works the same way with either.

| Configuration | Deploys | CloudFormation equivalent |
|---|---|---|
| `central/` | Custom bus and policy, log group, 5 rules, 8 metric filters, SNS topic, 2 alarms, dashboard | `templates/rds-posture-central.yaml` |
| `member/` | Forwarder IAM role and 5 forwarding rules on the default bus of one account and Region | `templates/rds-posture-member.yaml` |
| `member-stackset/` | A service-managed CloudFormation StackSet of the member template, for organization-wide rollout | `stackset-commands` output |

Requirements: Terraform 1.5 or later and the AWS provider 6.x (pinned in `versions.tf`). The
`.terraform.lock.hcl` files are committed with checksums for Linux, macOS and Windows.

## Deploy with the harness

The harness drives Terraform for you when you pass `--iac terraform`; it keeps local state, one
workspace per Region, under the configuration directories (ignored by git).

```bash
python3 harness/rdsposture.py --iac terraform preflight
python3 harness/rdsposture.py --iac terraform deploy-central --alarm-email you@example.com
python3 harness/rdsposture.py --iac terraform deploy-member --member-regions us-east-1,eu-west-2
python3 harness/rdsposture.py --iac terraform inject-test-events
python3 harness/rdsposture.py --iac terraform seed
python3 harness/rdsposture.py --iac terraform verify --hours 1 --member-regions us-east-1,eu-west-2
python3 harness/rdsposture.py --iac terraform destroy --member-regions us-east-1,eu-west-2
```

## Deploy with Terraform directly

The configurations carry no `provider` block, so they work both as root modules (Region and
credentials from the environment or your shared config) and as child modules called from your own
root configuration with your own provider, backend and policy checks.

```bash
export AWS_PROFILE=monitoring AWS_REGION=us-east-1
terraform -chdir=terraform/central init
terraform -chdir=terraform/central apply \
  -var alarm_email=dba-oncall@example.com \
  -var 'allowed_org_ids=["o-aaaaaaaaaa","o-bbbbbbbbbb"]'
BUS=$(terraform -chdir=terraform/central output -raw event_bus_arn)

# once per account and Region that must forward events (see the feed table in the README)
export AWS_REGION=eu-west-2
terraform -chdir=terraform/member init
terraform -chdir=terraform/member workspace select -or-create eu-west-2
terraform -chdir=terraform/member apply -var central_bus_arn=$BUS
```

As child modules:

```hcl
module "rds_posture_central" {
  source          = "git::https://github.com/<org>/<repo>.git//terraform/central?ref=main"
  alarm_email     = "dba-oncall@example.com"
  allowed_org_ids = ["o-aaaaaaaaaa"]
}

module "rds_posture_member_euw2" {
  source          = "git::https://github.com/<org>/<repo>.git//terraform/member?ref=main"
  central_bus_arn = module.rds_posture_central.event_bus_arn
  providers       = { aws = aws.eu_west_2 }
}
```

In HCP Terraform or Terraform Enterprise, give the central configuration one workspace and the
member configuration one workspace per account and Region (or one root module with provider
aliases); Sentinel or OPA policy sets apply to these workspaces like any other.

## Organization-wide rollout of the member configuration

Terraform can only create resources in accounts it has a provider for, and the forwarding rules
must exist in every member account. `member-stackset/` manages a service-managed CloudFormation
StackSet of `templates/rds-posture-member.yaml` from Terraform, which deploys to whole organizational
units and to accounts that join later. Apply it with credentials for each organization's management
account (or a CloudFormation delegated administrator with `call_as = "DELEGATED_ADMIN"`), and list
every organization ID in the central configuration's `allowed_org_ids`.

```bash
terraform -chdir=terraform/member-stackset init
terraform -chdir=terraform/member-stackset apply \
  -var central_bus_arn=$BUS \
  -var 'organizational_unit_ids=["r-xxxx"]' \
  -var 'regions=["us-east-1","eu-west-1","eu-west-2"]'
```

`python3 harness/rdsposture.py stackset-commands ...` prints this command with your values filled
in, next to the equivalent AWS CLI commands. The StackSet configuration passes `terraform validate`
but was not applied in the sandbox this project was built in, which has no AWS Organizations
management account; see `docs/multi-org.md` for the validation procedure.

## Variables

### central

| Variable | Default | Purpose |
|---|---|---|
| `bus_name` | `rds-posture-bus` | Custom event bus name |
| `allowed_org_ids` | `[]` | Organization IDs allowed to `PutEvents`; empty for single-account |
| `log_group_name` | `/rds-posture/events` | Raw event log group |
| `log_retention_days` | `365` | Log retention (CloudWatch Logs values only; 0 = never expire) |
| `alarm_email` | `""` | Optional e-mail subscription on the alerts topic |
| `metric_statuses` | `failed-only` | `failed-only` or `all` (adds PASSED/WARNING/NOT_AVAILABLE series) |
| `metric_namespace` | `RDSPosture` | Namespace of the derived metrics |
| `seed_event_source` | `rds-posture.seed` | Extra source every rule accepts for seeding and test events |
| `dashboard_name` | `RDS-Posture` | Dashboard name (account-wide, so distinct per deployment) |
| `alerts_topic_kms_key_id` | `""` | Optional customer managed KMS key for the alerts topic; its key policy must let `cloudwatch.amazonaws.com` use it |
| `tags` | `{}` | Tags for resources that support them |

Outputs: `event_bus_arn`, `event_bus_name`, `event_log_group_name`, `alerts_topic_arn`,
`dashboard_name`, `dashboard_url`.

### member

| Variable | Default | Purpose |
|---|---|---|
| `central_bus_arn` | required | Central bus ARN (`event_bus_arn` output) |
| `seed_event_source` | `rds-posture.seed` | Must match the central configuration |
| `enable_security_hub_rule` | `true` | `false` everywhere except the Security Hub delegated administrator (avoids duplicate findings) |
| `enable_health_rule` | `true` | `false` in member accounts when Health organizational view centralizes events |
| `exclude_health_backup_events` | `false` | `true` to drop the backup-Region copy of each Health event (`detail.backupEvent`) |
| `forwarder_role_name` | `rds-posture-forwarder-<region>` | IAM role name (IAM is global, so one per Region) |
| `tags` | `{}` | Tags for resources that support them |

Outputs: `forwarder_role_arn`, `rule_names`.

### member-stackset

| Variable | Default | Purpose |
|---|---|---|
| `central_bus_arn` | required | Central bus ARN |
| `organizational_unit_ids` | required | OU IDs or the root ID to deploy to |
| `regions` | `["us-east-1"]` | Regions per the feed table in the README |
| `stack_set_name` | `rds-posture-member` | StackSet name |
| `seed_event_source` | `rds-posture.seed` | Passed through to the template |
| `enable_security_hub_rule` / `enable_health_rule` | `true` / `true` | Passed through: switch feeds off where they would duplicate events |
| `exclude_health_backup_events` | `false` | Passed through: drop the backup-Region copy of each Health event |
| `call_as` | `SELF` | `SELF` or `DELEGATED_ADMIN` |
| `failure_tolerance_percentage` / `max_concurrent_percentage` | `10` / `25` | StackSet operation preferences |
| `tags` | `{}` | StackSet tags, propagated to its stacks |

## Keeping the two toolchains in step

Change the CloudFormation template and the Terraform configuration together: the event patterns,
metric filter patterns, alarm thresholds and dashboard queries are duplicated deliberately so each
toolchain is self-contained. `verify` checks the deployed resources (bus, rule count, metric filter
count, forwarding rules, every widget query) rather than the toolchain, so running it after a
change with each `--iac` value proves both still produce the same deployment.
