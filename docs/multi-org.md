# Feeding one dashboard from several AWS Organizations

Large enterprises often run more than one AWS Organization (separate payers, acquisitions,
regulatory boundaries). The dashboard handles that without any extra components, because
EventBridge event bus policies accept principals by organization ID. This page describes the
design, the exact configuration, the limits AWS documents, and the validation procedure to run
when a second account or organization becomes available.

## Design

```
Organization A                          Organization B
  member accounts (all OUs)               member accounts (all OUs)
    default bus --rule+role-->              default bus --rule+role-->
                        \                          /
                         v                        v
              central account (in A, in B, or standalone), us-east-1
                custom bus rds-posture-bus  <-- resource policy allows o-AAAA and o-BBBB
                  rules -> CloudWatch Logs -> metric filters -> alarms + dashboard
```

Every member account forwards **directly** to the central bus. Do not introduce a per-organization
hub bus in between: EventBridge does not forward an event it received from another account on to a
third account, so a two-hop design silently drops everything
([Sending and receiving events between AWS accounts](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-cross-account.html)).

## What the central stack does

The `AllowedOrgIds` parameter adds a resource-based policy statement to the bus. With
`AllowedOrgIds=o-aaaaaaaaaa,o-bbbbbbbbbb` the statement is:

```json
{
  "Sid": "AllowOrganizationPutEvents",
  "Effect": "Allow",
  "Principal": "*",
  "Action": "events:PutEvents",
  "Resource": "arn:aws:events:us-east-1:<central-account>:event-bus/rds-posture-bus",
  "Condition": { "StringEquals": { "aws:PrincipalOrgID": ["o-aaaaaaaaaa", "o-bbbbbbbbbb"] } }
}
```

This is the documented pattern for granting an organization access to an event bus
([Permissions for event buses](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-event-bus-perms.html)).
`aws:PrincipalOrgID` is evaluated against the organization of the *sending principal*, which is
the forwarding role in the member account, so a member of either organization can put events and
nobody else can.

## What the member stack does

The forwarding rules target the central bus ARN and carry an IAM role
(`rds-posture-forwarder-<region>`) whose only permission is `events:PutEvents` on that ARN.
EventBridge requires a role on every cross-account event bus target created after 2 March 2023, and
AWS recommends it precisely so that service control policies and organization boundaries still
apply to the forwarding
([Sending and receiving events between AWS accounts](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-cross-account.html)).

Cross-account forwarding also works across Regions, as long as the destination Region (here
us-east-1) is a supported cross-Region destination
([Sending and receiving events between AWS Regions](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-cross-region.html)).
The harness proved the cross-Region hop (eu-west-2 to us-east-1) in a single account; the
cross-account hop uses the identical target type with the identical role, plus the bus policy above.

The forwarded event keeps its original envelope: `account` is the member account, `region` is the
source Region, and `detail` is untouched. The dashboard queries group by those fields, which is why
one dashboard can show every organization side by side without any tagging or enrichment.

## Rolling the member stack out to each organization

Use a service-managed CloudFormation StackSet in *each* organization's management account (or a
CloudFormation delegated administrator). Service-managed permissions deploy to organizational
units, and automatic deployment adds the stack to accounts that join later
([StackSets with service-managed permissions](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/stacksets-orgs-manage-auto-deployment.html)).
The harness prints ready-to-run commands:

```bash
python3 harness/rdsposture.py stackset-commands \
  --central-bus-arn arn:aws:events:us-east-1:<central-account>:event-bus/rds-posture-bus \
  --ou-ids r-xxxx --regions us-east-1,eu-west-1,eu-west-2,eu-central-1
```

Terraform users have two options. `terraform/member-stackset` manages the same service-managed
StackSet from Terraform (apply it in each management account, or as a delegated administrator with
`call_as = "DELEGATED_ADMIN"`), so the rollout follows the organization automatically. Or, if every
account already has a Terraform workspace (an account-vending or landing-zone pipeline), add
`terraform/member` as a module to that baseline with the central bus ARN as input, once per Region
in the table below; the forwarder role name carries the Region, so several Regions of one account
do not collide. Either way, list every organization ID in the central configuration's
`allowed_org_ids`.

Where to deploy, per organization:

| Feed | Emitted in | Deploy the member stack in |
|---|---|---|
| Trusted Advisor check items | us-east-1 only (global service) | us-east-1, every account |
| AWS Health events | the Region of the affected resource, with a copy to its backup Region: us-west-2 for every other Region, us-east-1 for us-west-2 ([Region coverage](https://docs.aws.amazon.com/health/latest/ug/choosing-a-region.html)). With organizational view, the management or delegated administrator account also receives every member's events | every Region that hosts RDS, every account; or, with organizational view, that one account only (`EnableHealthRule=false` elsewhere). If the Regions include a backup Region, set `ExcludeHealthBackupEvents=true` to drop the backup copies (`detail.backupEvent`) |
| Security Hub CSPM findings | the delegated administrator's home Region (cross-Region aggregation collects every member and linked Region) | that Region, the delegated administrator account only |
| CloudTrail RDS API activity | the Region of the API call | every Region that hosts RDS, every account |
| AWS Config compliance changes | the Region of the rule | every Region with customer-managed RDS Config rules |

Deploying the Security Hub rule to every account does no harm (member accounts still emit their
own findings locally), but it duplicates events: the delegated administrator emits the aggregated
copy too. Set `EnableSecurityHubRule=false` in the organization-wide StackSet and keep the
Security Hub rule to the administrator account's own deployment, or accept the duplicates and
rely on the latest-state queries, which are idempotent per resource.

## Per-organization prerequisites

- Trusted Advisor organizational view (and TA Priority if you use it) is per organization; enable
  it in each management account ([Organizational view for Trusted Advisor](https://docs.aws.amazon.com/awssupport/latest/user/organizational-view.html)).
- Security Hub CSPM: one delegated administrator per organization, central configuration, and
  cross-Region aggregation with the home Region you deploy the member stack in
  ([Cross-Region aggregation](https://docs.aws.amazon.com/securityhub/latest/userguide/finding-aggregation.html)).
- AWS Health organizational view is optional: each account forwards its own Health events. If you enable
  it, keep the Health rule to the management or delegated administrator account, which receives a single
  feed for every member (`EnableHealthRule=false` in the organization-wide StackSet;
  [Aggregating AWS Health events](https://docs.aws.amazon.com/health/latest/ug/aggregating-health-events.html)).
- A CloudTrail trail logging management events in every RDS Region (an organization trail satisfies this).
- Seed the baseline once per organization from its Security Hub delegated administrator account:
  `python3 harness/rdsposture.py seed --central-bus-arn <arn> --securityhub-region <home-region>`.
  Seeding uses `PutEvents` on the central bus with the `rds-posture.seed` source, so the seeding
  principal must belong to an allowed organization (or be in the central account).

## Validation procedure (run when a second account is available)

1. In the central account, redeploy the central stack with `--org-ids <org-of-account-B>` (comma-add
   further organizations later). Confirm the bus policy in the EventBridge console shows the
   `AllowOrganizationPutEvents` statement.
2. In account B (any Region), deploy the member stack:
   `python3 harness/rdsposture.py --profile accountB --region eu-west-2 deploy-member --central-bus-arn <arn> --member-regions eu-west-2`.
3. From account B, inject the fixtures onto B's default bus:
   `python3 harness/rdsposture.py --profile accountB --region eu-west-2 inject-test-events`.
4. In the central account, run `verify --hours 1` and check that the events-by-source table lists
   the `rds-posture.seed` events and that the widget tables show `acct = <account B>` rows. The
   `account` envelope field proves the cross-account hop; the `region` field proves the cross-Region hop.
5. Negative test: deploy the member stack in an account outside the allowed organizations and
   inject again. The rule's target should report `FailedInvocations` in CloudWatch
   (`AWS/Events`, dimension `RuleName`) and nothing should arrive centrally.
6. Optional hardening once accounts are known: add an `account` allow-list to the central rules'
   event patterns, which AWS recommends whenever a bus accepts events from many accounts.

## Limits to keep in mind

- No third hop: events received from another account are not re-forwarded.
- Cross-account events are billed to the sending account as custom events
  ([EventBridge pricing](https://aws.amazon.com/eventbridge/pricing/)).
- PutEvents entries are limited to 256 KB; Security Hub findings are far below that, but the seed
  trims each finding to the fields the dashboard uses.
- Organization IDs, not account IDs, are the unit of trust here. If an account leaves an
  organization its forwarding stops working, which is the desired behaviour.
