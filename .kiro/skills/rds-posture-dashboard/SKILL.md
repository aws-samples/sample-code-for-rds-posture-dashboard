---
name: rds-posture-dashboard
description: Deploy, seed, test and verify the organization-wide Amazon RDS posture dashboard (EventBridge + CloudWatch, no Lambda) in an AWS account, and extend it safely. Use when asked to set up RDS posture monitoring, add an RDS feed or widget, prove an EventBridge pattern or Logs Insights query before deploying, or roll the member stack out with StackSets.
---

# RDS posture dashboard

Everything in this repo is driven by `harness/rdsposture.py` (AWS CLI v2 + Python, no
dependencies). Work in this order and treat the account as the test bench: prove, deploy, verify.
The infrastructure exists twice, as CloudFormation templates (`templates/`) and as Terraform
configurations (`terraform/`); ask which toolchain the user wants (default CloudFormation) and pass
`--iac terraform` as a global harness option when it is Terraform. Change both when you change one.

## Workflow

1. Identity first. Run `aws sts get-caller-identity` and confirm the account is the one the user
   intends. Never hard-code account IDs; the harness reads them from STS.
2. `python3 harness/rdsposture.py [--iac terraform] preflight`. Fix blockers it reports (support
   plan for Trusted Advisor, Config recorder, Security Hub CSPM + FSBP, a CloudTrail trail, Terraform
   on PATH for `--iac terraform`) before deploying.
3. `deploy-central` (us-east-1, once). Pass `--org-ids` for multi-Organization, `--alarm-email` for
   notifications, `--metric-statuses all` only if the user wants pass/fail ratios (costs more).
   `--dashboard-name` (global option) when a dashboard of that name already exists in the account.
4. `deploy-member --member-regions ...` in this account, or `stackset-commands` to print the
   organization rollout (CLI StackSet commands and the `terraform/member-stackset` apply). Regions:
   us-east-1 always (Trusted Advisor); the Security Hub delegated administrator's home Region;
   every Region that hosts RDS (CloudTrail API activity, Config, Health, which AWS Health delivers
   in the Region of the affected resource, not in us-east-1).
5. `inject-test-events` then `seed`, then `verify --hours 1`. Verify checks the deployed resources
   (bus, rule and filter counts, forwarding rules) and runs every dashboard query; a non-zero exit
   means something is missing or a widget is broken. Read `--out` JSON rather than trusting stdout.
6. `capture` to produce PNGs and redacted Markdown tables for documentation.

## Terraform specifics

- `terraform/central`, `terraform/member` and `terraform/member-stackset` are root configurations
  without provider blocks: Region and profile come from `AWS_REGION` / `AWS_PROFILE`, or the caller
  supplies the provider when using them as modules. AWS provider 6.x, Terraform 1.5+.
- The harness keeps local state with one workspace per Region (`terraform.tfstate.d/<region>`);
  if the user applied manually in the `default` workspace, destroy manually too.
- Run `terraform fmt -check -recursive` and `terraform validate` in each configuration after an
  edit; the committed `.terraform.lock.hcl` files carry checksums for Linux, macOS and Windows -
  regenerate them with `terraform providers lock -platform=...` if the provider constraint changes.
- Parity check after a change: deploy with each `--iac` (different Region or `--dashboard-name`)
  and diff `list-rules` / `list-targets-by-rule`, `describe-metric-filters`, `describe-alarms` and
  `get-dashboard` between the two; the only acceptable differences are Region and dashboard name.

## Extending safely

- Before adding or changing an EventBridge rule, prove the pattern:
  `aws events test-event-pattern --event-pattern file://p.json --event file://e.json` with a
  matching and a non-matching sample. `$or`, `prefix`, `wildcard` and `{"exists": false}` are valid.
- Before adding a metric filter, prove the pattern:
  `aws logs test-metric-filter --filter-pattern '...' --log-event-messages '<json>'`. Hyphenated
  keys work with dot notation (`$.detail-type`); bracket notation does not. Use `IS FALSE` /
  `NOT EXISTS` for booleans and absent keys. Keep dimensions low-cardinality; each unique
  combination is a billed metric.
- Before adding a Logs Insights widget, run the query with `aws logs start-query` /
  `get-query-results`. `dedup` cannot be followed by `filter` or `stats`; for latest-state-per-
  resource use `stats latest(field) as current by keys | filter current = "FAILED"`. Do not reuse an
  existing field alias as a stats alias. Backtick field names that contain hyphens.
- Custom events cannot use `aws.*` sources. Every rule accepts the `SeedEventSource` parameter's
  value so synthetic events can exercise the pipeline; feed metric filters key on `detail-type`, but
  the two alarm filters also require the genuine `aws.*` source, so synthetic events never raise an
  alarm (they count on the `SeedEvents` metric).
- Generate a real signal when possible (for example `aws rds modify-db-instance
  --no-deletion-protection` on a throwaway instance) and prove the alarm with
  `aws cloudwatch describe-alarm-history`.

## Example prompts

- "Run preflight in my current account and tell me what blocks the Trusted Advisor feed."
- "Deploy the central stack in us-east-1 with alerts to dba-oncall@example.com, then deploy the
  member stack in us-east-1 and eu-west-2 and verify."
- "Do the same with Terraform instead of CloudFormation, then show me the resources end up
  identical."
- "Print the StackSet commands to roll the member stack out to OU ou-abcd-11111111 in us-east-1,
  eu-west-1 and eu-west-2."
- "Add a widget that lists RDS instances whose backup retention dropped below 7 days, proving the
  Logs Insights query first."
- "Seed the dashboard from Security Hub in eu-west-2 and show me the events-by-source table."
- "Capture the dashboard for the runbook with account IDs redacted."
