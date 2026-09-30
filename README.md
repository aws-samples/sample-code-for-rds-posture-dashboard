# Organization-wide Amazon RDS posture dashboard with native AWS services

One CloudWatch dashboard, per AWS Organization or across several, that shows which Amazon RDS and
Amazon Aurora databases are missing deletion protection, Multi-AZ, backups or other
recommendations, who just switched a protection off, and which engines are heading into RDS
Extended Support. It uses only Amazon EventBridge, Amazon CloudWatch, AWS Trusted Advisor, AWS
Security Hub CSPM, AWS CloudTrail, AWS Config and AWS Health. No Lambda functions, no third-party
tooling, no data store to operate.

The Amazon EKS Dashboard gives platform teams an organization-wide view of their clusters. This
project gives database and platform teams the same thing for RDS.

This is sample code for demonstration and learning. It is not intended for production use without
your own review, testing and hardening.

## What you get

- Latest-state tables of failing RDS resources by control, check, account and Region. The Security
  Hub detail table also shows the engine and engine version supplied in ASFF resource details for
  RDS DB instances, clusters and snapshots. The tables use Security Hub CSPM `RDS.*` controls
  (deletion protection for instances and clusters, Multi-AZ, backups, backup plans, encryption,
  public access, logging) and the 100+ Trusted Advisor RDS and Aurora checks (including end of
  standard support, idle and right-sizing).
- A "who changed protection posture" table from CloudTrail: deletion protection switched off,
  databases created without it, databases deleted, with principal, source IP and time.
- Two alarms to an SNS topic: a transition alarm that fires once when someone disables deletion
  protection, and a state alarm that re-fires while unprotected databases exist.
- Hourly trend metrics in the `RDSPosture` namespace and the native `AWS/TrustedAdvisor` metrics.
- AWS Health planned lifecycle events for RDS (end of standard support notices) and, if you run
  your own Config rules, compliance changes on RDS resources.

## How it works

```
 member account (every account, via StackSet)                   central account (once)
 ┌──────────────────────────────────────────┐                   ┌─────────────────────────────────────┐
 │ default event bus                        │  cross-account /  │ custom bus rds-posture-bus          │
 │  Trusted Advisor check item events ─┐    │  cross-Region     │  rules ──► CloudWatch Logs          │
 │  Security Hub findings (RDS.*) ─────┼──► │ ────────────────► │           /rds-posture/events       │
 │  CloudTrail RDS API calls ──────────┤    │  (rule + role)    │             │                       │
 │  Config compliance changes ─────────┤    │                   │             ├─► metric filters      │
 │  Health RDS events ─────────────────┘    │                   │             │     └─► alarms ─► SNS │
 └──────────────────────────────────────────┘                   │             └─► Logs Insights       │
                                                                │                  widgets ─► dashboard│
                                                                └─────────────────────────────────────┘
```

Two deployments, available as CloudFormation templates (`templates/`) or as functionally identical
Terraform configurations (`terraform/`, see [terraform/README.md](terraform/README.md)):

- central (`templates/rds-posture-central.yaml` or `terraform/central`) – the bus, its resource
  policy (same account plus any number of organization IDs), the log group, eight metric filters,
  two alarms, the SNS topic and the 12-widget dashboard. Deploy once, in us-east-1, in your
  monitoring account.
- member (`templates/rds-posture-member.yaml` or `terraform/member`) – five forwarding rules on the
  default bus and the IAM role EventBridge requires for cross-account targets. Deploy to every
  account with a service-managed StackSet (from the CLI, or managed by Terraform with
  `terraform/member-stackset`); see the table below for Regions. Three parameters control which
  rules a deployment creates: `EnableSecurityHubRule` and `EnableHealthRule` (both default `true`)
  switch those feeds off where they would duplicate events, and `ExcludeHealthBackupEvents`
  (default `false`) drops the backup-Region copy of each AWS Health event. The Terraform variables
  `enable_security_hub_rule`, `enable_health_rule` and `exclude_health_backup_events` do the same.

Everything keys on the event `detail-type`, not the source, so seeded and test events are treated
exactly like live ones. The harness takes `--iac cloudformation` (default) or `--iac terraform`;
every other sub-command is toolchain-agnostic.

## Prerequisites

- AWS CLI v2 and Python 3.9+ (the harness is standard library only); Terraform 1.5+ if you choose
  `--iac terraform`
- Business Support+, Enterprise Support or Unified Operations plan in each account, for the
  Trusted Advisor feed (Security Hub, CloudTrail, Config and Health feeds do not need it)
- AWS Config recording in each Region you monitor (Security Hub controls and Trusted Advisor's
  Config-backed checks depend on it)
- Security Hub CSPM with the AWS Foundational Security Best Practices standard, a delegated
  administrator and cross-Region aggregation, so all `RDS.*` findings surface in one Region
- A CloudTrail trail logging management events in every Region that hosts RDS (an organization
  trail is enough)
- Nothing extra for the Health feed: each account forwards its own AWS Health events. If you use AWS
  Health organizational view, set `EnableHealthRule=false` in the organization-wide StackSet and
  deploy one member stack with the Health rule in the management or delegated administrator account
  (it receives every member's events); otherwise expect duplicates
- For a multi-Organization deployment: the organization IDs, and StackSet permissions in each
  management account

Run `python3 harness/rdsposture.py preflight` in any account to check these.

## Deploy

Single-account walkthrough (a sandbox is enough to see everything work):

```bash
python3 harness/rdsposture.py preflight
python3 harness/rdsposture.py deploy-central --alarm-email you@example.com
python3 harness/rdsposture.py deploy-member --member-regions us-east-1
python3 harness/rdsposture.py inject-test-events        # synthetic events through every rule
python3 harness/rdsposture.py seed                      # baseline from current Security Hub + Trusted Advisor state
python3 harness/rdsposture.py verify --hours 1          # resources, events, metrics, alarms, every widget query
```

Prefer Terraform? Add `--iac terraform` to the same commands, for example
`python3 harness/rdsposture.py --iac terraform deploy-central`, and the harness applies
`terraform/central` and `terraform/member` instead of the templates, with local state and one
workspace per Region. You can also run `terraform apply` yourself or call the configurations as
modules from your own root configuration; [terraform/README.md](terraform/README.md) has both, plus
every variable.

Organization rollout:

```bash
# central account, once
python3 harness/rdsposture.py deploy-central --org-ids o-aaaaaaaaaa,o-bbbbbbbbbb --alarm-email dba-oncall@example.com

# each organization's management account: prints the create-stack-set / create-stack-instances
# commands and the equivalent terraform/member-stackset apply
python3 harness/rdsposture.py stackset-commands --central-bus-arn <EventBusArn output> \
  --ou-ids r-xxxx --regions us-east-1,eu-west-1,eu-west-2,eu-central-1

# Security Hub delegated administrator account of each organization, once
python3 harness/rdsposture.py seed --central-bus-arn <EventBusArn output> --securityhub-region eu-west-2
```

Where each feed is emitted, and therefore where the member stack must exist:

| Feed | Emitted in | Member stack needed in |
|---|---|---|
| Trusted Advisor check items | us-east-1 (global service) | us-east-1, every account |
| AWS Health RDS events | Region of the affected resource, plus a copy to its backup Region (us-west-2 backs up every other Region; us-east-1 backs up us-west-2). With organizational view, the management or delegated administrator account also receives every member's events | every RDS Region, every account (the CloudTrail row already covers these Regions); with organizational view, that one account only (`EnableHealthRule=false` elsewhere). If the Regions include a backup Region, set `ExcludeHealthBackupEvents=true` so the primary copy counts once |
| Security Hub CSPM findings | delegated administrator's home Region | that Region, administrator account (`EnableSecurityHubRule=false` in the organization-wide StackSet) |
| CloudTrail RDS API activity | Region of the API call | every RDS Region, every account |
| Config compliance changes | Region of the rule | every Region with customer-managed RDS rules |

[docs/multi-org.md](docs/multi-org.md) covers the multi-Organization design, the bus policy, and
the validation procedure to run with a second account.

## Seeding the baseline

The tables are built from events, so on day one they only know about changes that happened after
deployment. The `seed` command closes that gap: it reads the current `RDS.*` findings from Security
Hub (`GetFindings`, FAILED by default) and the flagged resources of every RDS and Aurora Trusted
Advisor check (`DescribeTrustedAdvisorCheckResult`), reshapes them into the same event formats the
live feeds use, and puts them on the central bus with the `rds-posture.seed` source. From then on
the latest-state queries (`stats latest(status) by control, account, resource`) let every live
event supersede the seeded one for that resource.

Run the seed from the Security Hub delegated administrator account (its `GetFindings` returns
every member's findings) and, for Trusted Advisor, from each account whose checks you want
included, or use the organizational-view report as the source. A single-account seed takes about
20 seconds: the harness reads the Trusted Advisor check summaries first and only fetches results
for checks that flag something, with low concurrency because the Support API throttles. Security Hub and Config remain the
authoritative "right now" inventory; the dashboard is the operational view and change feed.

## Cost

The estimates in this section use public US East (N. Virginia) prices as of September 2026
from the [CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/) and
[EventBridge pricing](https://aws.amazon.com/eventbridge/pricing/) pages; verify current prices for
both your Region and usage tier. The bill is dominated by custom metrics, which CloudWatch prices
per unique metric (name plus dimension values) per month, about $0.30 each. The dimensions are check name, control ID and
status, never account or resource, so the count does not grow with the size of the estate. With
the default `MetricStatuses=failed-only` the Security Hub metric has one series per failing control
and the Trusted Advisor metric one per flagged check and status: typically 50 to 150 series
($15 to $45 per month), and about 300 series ($90) in the worst case where every RDS check and
control flags something. Switching to `MetricStatuses=all` adds PASSED and NOT_AVAILABLE series,
useful for pass/fail ratios but two to three times the metric count. Other line items: EventBridge cross-account events at $1 per
million (billed to the sender), CloudWatch Logs ingestion (a few GB per month for hundreds of
accounts), one dashboard ($3/month beyond the free tier) and two alarms. CloudWatch Logs Insights
charges by bytes scanned; seven log widgets query the selected window when the dashboard loads, and
`verify` and `capture` query them too. This cost scales with log volume, widget count, time range and
refresh frequency. Trusted Advisor, Security Hub, CloudTrail management events and AWS Health carry
no extra charge for this pattern.

## Verify and capture

`verify` fails non-zero if a stack is not complete or a widget query does not parse, so it doubles
as a smoke test in a pipeline. `verify` and `capture` default to the dashboard's 168-hour (7-day)
window; use `verify --hours 1` immediately after test injection. `capture` saves every metric widget
as a PNG (`GetMetricWidgetImage`) and every table widget as redacted Markdown for documentation.

## Limits and caveats

- Trusted Advisor delivers events on a best-effort basis, only in us-east-1, and only for
  Business+/Enterprise/Unified Operations plans. Treat it as a change feed, not as evidence.
- Security Hub re-emits a finding whenever a control re-evaluates: on a resource change for
  change-triggered controls such as RDS.7 and RDS.8, and at least once every 24 hours regardless
  (periodic controls run every 12 or 24 hours). The state alarm therefore re-fires while a
  condition persists. Use the CloudTrail transition alarm for paging.
- The Security Hub detail table reads `Engine` and `EngineVersion` from ASFF resource details for
  RDS DB instances, clusters and snapshots. Other Security Hub resource types, and the Trusted
  Advisor, Config, CloudTrail modify/delete and Health event formats, do not provide one consistent
  current-version field; those rows or feeds therefore leave the columns blank rather than infer a
  value. A CloudTrail create event can carry a requested version, which is not necessarily current.
- AWS Health delivers Region-specific events in the Region of the affected resource and copies
  each one to a backup Region (us-west-2). A member deployment in us-west-2 therefore also
  receives the copies (`detail.backupEvent` is true); set `ExcludeHealthBackupEvents=true`
  (`exclude_health_backup_events` in Terraform) if you deploy there and the primary Regions are
  covered, so the dashboard counts each Health event once. Leave it `false` when the backup copy
  may be the only copy an account receives.
- The latest-state tables only see events inside the dashboard time range, and Security Hub
  re-evaluates change-triggered controls at most every ~24 hours. The dashboard therefore defaults
  to the last 7 days; keep the range at 7 days or more (or reaching back to your last seed), or
  currently-failing resources can drop out of the tables.
- AWS Config does not emit compliance-change events for the service-linked rules Security Hub
  creates; the Config feed only carries customer-managed rules, for example a conformance pack.
- EventBridge does not forward an event received from another account to a third account, so
  every member account must target the central bus directly.
- The tables reflect events since deployment plus the seed; a resource that was never evaluated
  again after seeding keeps its seeded state.
- The central stack uses fixed names for the log group, the alerts topic and the alarms, so
  deploy it once per account. (`DashboardName` only exists because CloudWatch dashboard names are
  account-wide.)
- CloudWatch dashboards are the right tool for counts, lists and alarms. For ownership
  enrichment, cost joins and the Extended Support cost projection, pair this with the
  Cloud Intelligence Dashboards (Trusted Advisor Organizational and Extended Support Cost
  Projection), which read the same sources on a schedule and do not conflict with this deployment.

## How Kiro built and verified this

The templates and harness were built with Kiro in an agentic loop that treated the AWS account as
the test bench: `preflight` before any change; `aws events test-event-pattern` and
`aws logs test-metric-filter` to prove every event pattern and filter pattern against sample
events before deploying; `aws logs start-query` on every dashboard widget after each deploy so a
Logs Insights syntax error surfaces as a failed step rather than an empty widget; a real
`ModifyDBInstance --no-deletion-protection` on a throwaway instance to fire the transition alarm;
and `describe-alarm-history` as the proof. That loop caught three things worth knowing:
`dedup` cannot be followed by `filter` in Logs Insights (use `stats latest()`), custom events
cannot use `aws.*` sources (hence the seed source parameter), and Config stays silent for Security
Hub's service-linked rules. The Terraform port went through the same loop: deployed side by side
with the CloudFormation stacks in another Region, then every rule, target, metric filter, alarm,
policy and the dashboard body diffed between the two deployments until the only differences left
were the Region and the dashboard name. That run also showed that EventBridge rules created seconds
earlier can miss events while they propagate, which is why `inject-test-events` now waits and
confirms delivery instead of assuming it. The `.kiro/skills/rds-posture-dashboard` skill lets you
repeat the same loop in your own account with a few prompts.

## Clean up

```bash
python3 harness/rdsposture.py destroy --member-regions us-east-1,eu-west-2
# or, for a Terraform deployment
python3 harness/rdsposture.py --iac terraform destroy --member-regions us-east-1,eu-west-2
```

Deleting the stacks (or destroying the Terraform state) removes the bus, rules, log group, metric
filters, alarms, topic and dashboard. Metrics already published expire from CloudWatch on their own.

## Security considerations

The member role can only `events:PutEvents` on the central bus ARN. The central bus accepts events
from the central account and from the organizations you list, nothing else. The log group's
resource policy is conditioned on `aws:SourceAccount`, so only this account's EventBridge can
write to it. The log group holds event envelopes and finding summaries (resource ARNs, control
IDs, principals from CloudTrail); restrict read access to it like any operational log, and set
`LogRetentionDays` (default 365 days) to your policy. The alerts topic can be encrypted with a
customer managed KMS key (`AlertsTopicKmsKeyId` / `alerts_topic_kms_key_id`) whose key policy lets
`cloudwatch.amazonaws.com` use it; the AWS managed `alias/aws/sns` key does not work with
CloudWatch alarms, so the topic is unencrypted by default. Everything runs under the credentials
of the operator who runs the harness. Give that principal only what the commands need:
CloudFormation (or Terraform) to create the stacks, which in turn create the EventBridge,
CloudWatch Logs, CloudWatch, SNS and IAM (member role) resources; `events:PutEvents` on the central
bus for `seed` and `inject-test-events`; EventBridge, CloudWatch and Logs read access for `verify`
and `capture`; and read access to Security Hub, Support (Trusted Advisor), Config, CloudTrail and
RDS for `preflight` and `seed`. Run the walkthrough in a sandbox account first.

## Security issue notifications

If you discover a potential security issue in this project we ask that you notify AWS/Amazon
Security via our [vulnerability reporting page](https://aws.amazon.com/security/vulnerability-reporting/).
Please do **not** create a public GitHub issue. See [CONTRIBUTING](CONTRIBUTING.md) for details.

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.
