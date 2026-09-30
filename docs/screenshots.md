# Screenshot and capture checklist

Everything below can be produced from a single sandbox account with one throwaway RDS instance;
no customer data is needed. `harness/rdsposture.py capture` writes the metric charts as PNG and
the table widgets as redacted Markdown into `docs/images/` (see the index it generates there).
Run `python3 harness/rdsposture.py capture --hours 168` before publication. Use a 7-day
console range for screenshots, replace account IDs with `111122223333`, and replace resource names
with stable example aliases.

## Generate the data first

1. `deploy-central`, `deploy-member`, `inject-test-events`, `seed` (see README).
2. Create a throwaway instance that fails the interesting controls and wait about 30 minutes for
   Security Hub to evaluate it:
   `aws rds create-db-instance --db-instance-identifier rds-posture-test-1 --engine postgres --db-instance-class db.t4g.micro --allocated-storage 20 --manage-master-user-password --master-username postgres --backup-retention-period 0 --no-multi-az --no-deletion-protection --no-publicly-accessible --storage-encrypted`
3. Fire the transition alarm with a real API call:
   `aws rds modify-db-instance --db-instance-identifier rds-posture-test-1 --deletion-protection --apply-immediately`
   then a minute later
   `aws rds modify-db-instance --db-instance-identifier rds-posture-test-1 --no-deletion-protection --apply-immediately`
4. Run `verify --hours 1` and keep the JSON report; the alarm history lines are the evidence.

## Console screenshots to take

| # | Where | What to show |
|---|---|---|
| 1 | CloudWatch > Dashboards > RDS-Posture | Full dashboard, 7-day range, tables populated |
| 2 | Same, widget "Failing RDS resources - Security Hub detail" | Rows for the test instance: RDS.5, RDS.8, RDS.11, with `engine` and `engineVersion` visible |
| 3 | Same, widget "Who changed RDS protection posture" | The ModifyDBInstance row with principal and deletionProtection = false |
| 4 | CloudWatch > Alarms > rds-posture-deletion-protection-disabled-api > History | OK to ALARM transition right after the API call |
| 5 | EventBridge > Event buses > rds-posture-bus > Rules | The five rules |
| 6 | EventBridge > Rules (default bus) > rds-posture-fwd-api-activity > Event pattern | The `$or` pattern |
| 7 | Security Hub > Findings, filter `ComplianceSecurityControlId` prefix RDS. | Source of truth next to the dashboard |
| 8 | Trusted Advisor > Recommendations, filter RDS | The same items surfacing in TA |

## Redaction

Account IDs appear in ARNs, principals and the `acct` column. Replace every 12-digit number with
`111122223333`. Replace database, cluster, snapshot and subnet-group identifiers with stable
`example-*` aliases. Replace IAM identities and source IP addresses with documentation values.

## Clean up

`aws rds delete-db-instance --db-instance-identifier rds-posture-test-1 --skip-final-snapshot`
and `harness/rdsposture.py destroy` when the screenshots are done.
