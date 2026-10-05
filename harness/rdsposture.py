#!/usr/bin/env python3
"""rdsposture - deploy, seed, test, verify and capture the RDS posture dashboard.

Standard library only; every AWS call goes through the AWS CLI v2 that is already on your PATH,
so the harness inherits your profiles, SSO sessions and MFA handling. Nothing here stores
credentials or account IDs - the account is always read from STS at run time.

Pick the infrastructure-as-code toolchain with --iac: cloudformation (default, templates/) or
terraform (terraform/, needs Terraform 1.5+ on PATH). Both produce the same resources, and every
other sub-command works the same way regardless of how the resources were created.

Sub-commands (run with -h for options):
  preflight          Check the prerequisites the dashboard depends on (support plan, Config, Security Hub, CloudTrail).
  deploy-central     Create/update the central deployment (bus, log group, metrics, alarms, dashboard).
  deploy-member      Create/update the member (forwarding) deployment in one or more Regions of THIS account.
  stackset-commands  Print the commands that roll the member stack out to an organization (StackSet, CLI or Terraform).
  seed               Seed the dashboard with the current Security Hub / Trusted Advisor state (baseline).
  inject-test-events Put synthetic events (fixtures in tests/events) to exercise every rule and widget.
  verify             Prove the deployment works: resources, events, metrics, alarms, every dashboard query.
  capture            Save metric widgets as PNG and table widgets as redacted Markdown for documentation.
  destroy            Delete the member deployment(s) and the central deployment.
"""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import datetime as dt
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

REPO = pathlib.Path(__file__).resolve().parent.parent
TEMPLATES = REPO / "templates"
TERRAFORM_DIR = REPO / "terraform"
FIXTURES = REPO / "tests" / "events"
CENTRAL_STACK = "rds-posture-central"
MEMBER_STACK = "rds-posture-member"
BUS_NAME = "rds-posture-bus"
LOG_GROUP = "/rds-posture/events"
DASHBOARD = "RDS-Posture"
NAMESPACE = "RDSPosture"
CENTRAL_RULES, MEMBER_RULES, METRIC_FILTERS = 5, 5, 9
REDACTED_ACCOUNT = "111122223333"

# ----------------------------------------------------------------------------- plumbing

class Aws:
    """Thin wrapper around the AWS CLI.

    Every call is an argv list that starts with the static program name and never goes through a
    shell, so the arguments reach the CLI verbatim and nothing here is parsed as shell syntax.
    """

    def __init__(self, profile=None, region="us-east-1"):
        if not shutil.which("aws"):
            sys.exit("aws CLI not found on PATH - install AWS CLI v2")
        self.profile = profile
        self.region = region

    def run(self, *args, region=None, timeout=300, expect_json=True):
        profile = ["--profile", self.profile] if self.profile else []
        r = subprocess.run(["aws", *args, "--region", region or self.region, "--output", "json", *profile],
                           capture_output=True, text=True, timeout=timeout)
        if r.returncode != 0:
            raise RuntimeError(f"aws {' '.join(args[:2])} failed: {r.stderr.strip()[-400:]}")
        if not expect_json or not r.stdout.strip():
            return r.stdout
        return json.loads(r.stdout)

    def try_run(self, *args, **kw):
        try:
            return self.run(*args, **kw), None
        except Exception as e:  # noqa: BLE001
            return None, str(e)

    def account(self):
        return self.run("sts", "get-caller-identity")["Account"]


class Report:
    """Collects human-readable lines and structured facts; optionally writes JSON."""

    def __init__(self, out=None):
        self.lines, self.facts, self.out = [], {}, out
        self.ok = True

    def log(self, line, **facts):
        print(line, flush=True)
        self.lines.append(line)
        self.facts.update(facts)
        if self.out:
            pathlib.Path(self.out).write_text(json.dumps({"lines": self.lines, "facts": self.facts, "ok": self.ok}, indent=2, default=str))

    def fail(self, line, **facts):
        self.ok = False
        self.log("FAIL " + line, **facts)


class Terraform:
    """Thin wrapper around the terraform CLI for the root configurations in terraform/.

    State stays local (the default backend) and each Region gets its own workspace, so the member
    configuration can be applied to several Regions of one account without the states colliding.
    Region and profile reach the AWS provider through the environment, exactly as for the CLI.
    """

    def __init__(self, aws):
        if not shutil.which("terraform"):
            sys.exit("terraform not found on PATH - install Terraform 1.5+ or use --iac cloudformation")
        self.aws = aws

    def run(self, module, *args, region, timeout=1800):
        env = dict(os.environ, AWS_REGION=region, AWS_DEFAULT_REGION=region, TF_IN_AUTOMATION="1", TF_INPUT="0")
        if self.aws.profile:
            env["AWS_PROFILE"] = self.aws.profile
        # Static program name, argv list, no shell: the module path and arguments are passed verbatim.
        r = subprocess.run(["terraform", f"-chdir={TERRAFORM_DIR / module}", *args],
                           capture_output=True, text=True, timeout=timeout, env=env)
        return r.returncode, r.stdout, r.stderr

    def select(self, module, region, create=True):
        rc, _, err = self.run(module, "init", "-input=false", "-no-color", region=region)
        if rc:
            raise RuntimeError(f"terraform init ({module}) failed: {err.strip()[-500:]}")
        rc, _, err = self.run(module, "workspace", "select", *(["-or-create"] if create else []), region, region=region)
        if rc:
            raise RuntimeError(f"terraform workspace select ({module}, {region}) failed: {err.strip()[-500:]}")

    @staticmethod
    def var_args(variables):
        return [f"-var={k}={v if isinstance(v, str) else json.dumps(v)}" for k, v in variables.items() if v not in (None, "")]

    def apply(self, rep, module, region, variables):
        self.select(module, region)
        rc, _, err = self.run(module, "apply", "-auto-approve", "-input=false", "-no-color", *self.var_args(variables), region=region)
        if rc:
            rep.fail(f"terraform apply {module} in {region}: {err.strip()[-800:]}")
            return {}
        outputs = self.outputs(module, region)
        rep.log(f"terraform {module} in {region}: applied ({self.state_count(module, region)} resources in state)")
        return outputs

    def destroy(self, rep, module, region, variables):
        self.select(module, region)
        rc, _, err = self.run(module, "destroy", "-auto-approve", "-input=false", "-no-color", *self.var_args(variables), region=region)
        (rep.fail if rc else rep.log)(f"terraform destroy {module} in {region}: {err.strip()[-800:] if rc else 'done'}")

    def outputs(self, module, region):
        rc, out, _ = self.run(module, "output", "-json", region=region)
        return {k: v["value"] for k, v in json.loads(out).items()} if rc == 0 and out.strip() else {}

    def state_count(self, module, region):
        rc, out, _ = self.run(module, "state", "list", region=region)
        return len(out.split()) if rc == 0 else 0


def redact(text, account):
    """Scrub account IDs, IAM session/user names and IPv4 addresses before anything is written to docs."""
    text = text.replace(account, REDACTED_ACCOUNT)
    text = re.sub(r"\b\d{12}\b", REDACTED_ACCOUNT, text)
    text = re.sub(r"(assumed-role/)[^/\s|]+/[^\s|]+", r"\1example-role/example-session", text)
    text = re.sub(r"(:role/)[^\s|]+", r"\1example-role", text)
    text = re.sub(r"(:user/)[^\s|]+", r"\1example-user", text)
    return re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "203.0.113.0", text)


def stack_status(aws, name, region=None):
    data, err = aws.try_run("cloudformation", "describe-stacks", "--stack-name", name, region=region)
    if not data:
        return None, {}
    st = data["Stacks"][0]
    return st["StackStatus"], {o["OutputKey"]: o["OutputValue"] for o in st.get("Outputs", [])}


def stack_failures(aws, name, region=None):
    data, _ = aws.try_run("cloudformation", "describe-stack-events", "--stack-name", name, region=region)
    return [f"{e['LogicalResourceId']}: {e.get('ResourceStatusReason')}" for e in (data or {}).get("StackEvents", [])
            if e.get("ResourceStatus", "").endswith("FAILED") and e.get("ResourceStatusReason")][:8]


def deploy(aws, rep, name, template, params, region=None):
    cmd = ["cloudformation", "deploy", "--stack-name", name, "--template-file", str(template),
           "--capabilities", "CAPABILITY_IAM", "CAPABILITY_NAMED_IAM", "--no-fail-on-empty-changeset"]
    if params:
        cmd += ["--parameter-overrides", *[f"{k}={v}" for k, v in params.items()]]
    _, err = aws.try_run(*cmd, region=region, timeout=1200, expect_json=False)
    status, outputs = stack_status(aws, name, region)
    if err or not status or not status.endswith("_COMPLETE") or "ROLLBACK" in status:
        rep.fail(f"stack {name} in {region or aws.region}: {status} {err or ''}")
        for f in stack_failures(aws, name, region):
            rep.log("   " + f)
    else:
        rep.log(f"stack {name} in {region or aws.region}: {status}")
    return status, outputs


def logs_query(aws, query, hours, region=None, limit=200, wait=60, log_group=LOG_GROUP):
    end, start = int(time.time()), int(time.time() - hours * 3600)
    # Widget queries name their log group in a SOURCE clause; query that group, not the default,
    # so a deployment with a custom log_group_name verifies the group it actually uses.
    q, group = query, log_group
    m = re.match(r"^\s*SOURCE\s+'([^']+)'\s*(?:\|\s*)?(.*)$", query, re.IGNORECASE | re.DOTALL)
    if m:
        group = m.group(1)
        q = m.group(2).strip() or "fields @timestamp, @message"
    started = aws.run("logs", "start-query", "--log-group-name", group, "--start-time", str(start),
                      "--end-time", str(end), "--query-string", q, "--limit", str(limit), region=region)
    qid = started["queryId"]
    deadline = time.time() + wait
    while time.time() < deadline:
        time.sleep(3)
        res = aws.run("logs", "get-query-results", "--query-id", qid, region=region)
        if res.get("status") in ("Complete", "Failed", "Cancelled", "Timeout"):
            rows = [{c["field"]: c["value"] for c in r if c["field"] != "@ptr"} for r in res.get("results", [])]
            return res["status"], rows
    return "Timeout", []


def put_events(aws, entries, region=None):
    """PutEvents in batches of 10 (the API limit). Returns (sent, failed)."""
    sent = failed = 0
    for i in range(0, len(entries), 10):
        batch = entries[i:i + 10]
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(batch, fh)
            path = fh.name
        try:
            res = aws.run("events", "put-events", "--entries", "file://" + path, region=region)
            failed += res.get("FailedEntryCount", 0)
            sent += len(batch) - res.get("FailedEntryCount", 0)
        finally:
            os.unlink(path)
    return sent, failed

# ----------------------------------------------------------------------------- sub-commands

def cmd_preflight(a):
    aws, rep = Aws(a.profile, a.region), Report(a.out)
    account = aws.account()
    rep.log(f"account {account}, central Region {a.region}", account=account)

    checks, err = aws.try_run("support", "describe-trusted-advisor-checks", "--language", "en", region="us-east-1")
    if checks:
        rds = [c["name"] for c in checks["checks"] if "RDS" in c["name"] or "Aurora" in c["name"]]
        rep.log(f"Trusted Advisor API available: {len(checks['checks'])} checks, {len(rds)} RDS/Aurora", ta_checks=len(rds))
    else:
        rep.fail("Trusted Advisor API unavailable - Business Support+, Enterprise Support or Unified Operations plan required for the TA feed", ta_error=err)

    rec, err = aws.try_run("configservice", "describe-configuration-recorder-status")
    recording = any(r.get("recording") for r in (rec or {}).get("ConfigurationRecordersStatus", []))
    (rep.log if recording else rep.fail)(f"AWS Config recorder recording in {a.region}: {recording}", config_recording=recording)

    hub, err = aws.try_run("securityhub", "describe-hub")
    if hub:
        stds, _ = aws.try_run("securityhub", "get-enabled-standards")
        names = [s["StandardsArn"].split("/")[-3] for s in (stds or {}).get("StandardsSubscriptions", [])]
        rep.log(f"Security Hub CSPM enabled (finding generator {hub.get('ControlFindingGenerator')}), standards: {names}", securityhub=True)
        if not any("foundational" in n for n in names):
            rep.log("   note: enable the AWS Foundational Security Best Practices standard for the RDS.* controls")
    else:
        rep.fail("Security Hub CSPM not enabled in this Region - the RDS.* control feed will be empty", securityhub=False)

    trails, _ = aws.try_run("cloudtrail", "describe-trails", "--include-shadow-trails")
    live = []
    for t in (trails or {}).get("trailList", []):
        st, _ = aws.try_run("cloudtrail", "get-trail-status", "--name", t["TrailARN"], region=t.get("HomeRegion", a.region))
        if (st or {}).get("IsLogging") and (t.get("IsMultiRegionTrail") or t.get("HomeRegion") == a.region):
            live.append(t["Name"])
    (rep.log if live else rep.fail)(f"CloudTrail trails logging management events here: {live or 'none - the API-activity feed needs one'}", trails=live)

    inst, _ = aws.try_run("rds", "describe-db-instances")
    clus, _ = aws.try_run("rds", "describe-db-clusters")
    rep.log(f"RDS in {a.region}: {len((inst or {}).get('DBInstances', []))} instances, {len((clus or {}).get('DBClusters', []))} clusters")

    sample = json.dumps({"detail-type": "x", "detail": {"check-name": "Amazon RDS Backups", "status": "WARN"}})
    t, err = aws.try_run("logs", "test-metric-filter", "--filter-pattern", '{ ($.detail-type = "x") && ($.detail.check-name = "Amazon RDS Backups") }',
                         "--log-event-messages", sample)
    rep.log(f"metric filter pattern with hyphenated JSON keys accepted: {bool(t and t.get('matches'))}")

    for name in (CENTRAL_STACK, MEMBER_STACK):
        st, _ = stack_status(aws, name)
        rep.log(f"existing stack {name}: {st or 'absent'}")
    if shutil.which("terraform"):
        ver = subprocess.run(["terraform", "version", "-json"], capture_output=True, text=True, timeout=60).stdout
        rep.log(f"terraform on PATH: {json.loads(ver).get('terraform_version') if ver.strip() else 'yes'} (--iac terraform available)")
    elif a.iac == "terraform":
        rep.fail("terraform not found on PATH - install Terraform 1.5+ or use --iac cloudformation")
    rep.log("preflight " + ("PASSED" if rep.ok else "found blockers - fix them before deploying"))
    return 0 if rep.ok else 1


def cmd_deploy_central(a):
    aws, rep = Aws(a.profile, a.region), Report(a.out)
    if a.iac == "terraform":
        variables = {"allowed_org_ids": [o.strip() for o in a.org_ids.split(",")] if a.org_ids else None, "alarm_email": a.alarm_email,
                     "metric_statuses": a.metric_statuses, "bus_name": a.bus_name, "log_retention_days": a.log_retention_days,
                     "seed_event_source": a.seed_source, "dashboard_name": a.dashboard_name}
        rep.log(f"applying terraform/central to {aws.account()} / {a.region} with {Terraform.var_args(variables)}")
        outputs = Terraform(aws).apply(rep, "central", a.region, variables)
    else:
        params = {k: v for k, v in {"AllowedOrgIds": a.org_ids, "AlarmEmail": a.alarm_email, "MetricStatuses": a.metric_statuses,
                                    "BusName": a.bus_name, "LogRetentionDays": a.log_retention_days, "SeedEventSource": a.seed_source,
                                    "DashboardName": a.dashboard_name}.items() if v}
        rep.log(f"deploying {a.stack_name} to {aws.account()} / {a.region} with {params or 'template defaults'}")
        _, outputs = deploy(aws, rep, a.stack_name, TEMPLATES / "rds-posture-central.yaml", params)
    for k, v in outputs.items():
        rep.log(f"   {k}: {v}", **{k: v})
    return 0 if rep.ok else 1


def resolve_bus_arn(aws, a):
    if a.central_bus_arn:
        return a.central_bus_arn
    if a.iac == "terraform":
        tf = Terraform(aws)
        tf.select("central", a.region)
        arn = tf.outputs("central", a.region).get("event_bus_arn")
        if not arn:
            sys.exit(f"central bus ARN not given and terraform/central has no state in workspace {a.region} - pass --central-bus-arn")
        return arn
    _, outputs = stack_status(aws, a.central_stack_name)
    if not outputs.get("EventBusArn"):
        sys.exit("central bus ARN not given and central stack not found - pass --central-bus-arn")
    return outputs["EventBusArn"]


def cmd_deploy_member(a):
    aws, rep = Aws(a.profile, a.region), Report(a.out)
    bus = resolve_bus_arn(aws, a)
    for rg in a.member_regions.split(","):
        if a.iac == "terraform":
            Terraform(aws).apply(rep, "member", rg.strip(), {"central_bus_arn": bus, "seed_event_source": a.seed_source})
        else:
            deploy(aws, rep, a.stack_name, TEMPLATES / "rds-posture-member.yaml",
                   {"CentralBusArn": bus, "SeedEventSource": a.seed_source}, region=rg.strip())
    rep.log("note: freshly created rules can take up to a minute to start matching events; inject-test-events waits and confirms delivery")
    return 0 if rep.ok else 1


def cmd_stackset_commands(a):
    aws = Aws(a.profile, a.region)
    bus = resolve_bus_arn(aws, a)
    call_as = " --call-as DELEGATED_ADMIN" if a.delegated_admin else ""
    print(f"""# Run from the organization's management account (or a CloudFormation delegated administrator).
# 1. Create the StackSet once per organization (service-managed permissions, auto-deploy to new accounts).
aws cloudformation create-stack-set --stack-set-name {a.stackset_name} \\
  --template-body file://{TEMPLATES / 'rds-posture-member.yaml'} \\
  --parameters ParameterKey=CentralBusArn,ParameterValue={bus} \\
  --capabilities CAPABILITY_NAMED_IAM --permission-model SERVICE_MANAGED \\
  --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false{call_as}

# 2. Deploy instances to the OUs and Regions that need them.
#    us-east-1 everywhere (Trusted Advisor); the Security Hub delegated administrator's home Region;
#    every Region that hosts RDS (CloudTrail API activity, Config, Health).
aws cloudformation create-stack-instances --stack-set-name {a.stackset_name} \\
  --deployment-targets OrganizationalUnitIds={a.ou_ids} \\
  --regions {' '.join(a.regions.split(','))} \\
  --operation-preferences FailureTolerancePercentage=10,MaxConcurrentPercentage=25,RegionConcurrencyType=PARALLEL{call_as}

# 3. Repeat 1-2 in every other organization that should feed the same central bus, and list all
#    organization IDs in the central stack's AllowedOrgIds parameter (Terraform: allowed_org_ids).

# Terraform alternative - the same service-managed StackSet, managed from terraform/member-stackset:
terraform -chdir={TERRAFORM_DIR / 'member-stackset'} init
terraform -chdir={TERRAFORM_DIR / 'member-stackset'} apply \\
  -var central_bus_arn={bus} \\
  -var 'organizational_unit_ids={json.dumps(a.ou_ids.split(','))}' \\
  -var 'regions={json.dumps(a.regions.split(','))}'{' -var call_as=DELEGATED_ADMIN' if a.delegated_admin else ''}
""")
    return 0


def seed_securityhub(aws, rep, a):
    filters = {"ComplianceSecurityControlId": [{"Value": "RDS.", "Comparison": "PREFIX"}],
               "RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}]}
    if not a.include_passed:
        filters["ComplianceStatus"] = [{"Value": "FAILED", "Comparison": "EQUALS"}]
    data = aws.run("securityhub", "get-findings", "--filters", json.dumps(filters), "--max-items", str(a.max_items),
                   region=a.securityhub_region, timeout=900)
    keep = ("SchemaVersion", "Id", "ProductArn", "GeneratorId", "AwsAccountId", "Title", "Description", "Severity",
            "Compliance", "Resources", "Workflow", "RecordState", "CreatedAt", "UpdatedAt", "ProductFields", "Region")
    entries = []
    for f in data.get("Findings", []):
        trimmed = {k: f[k] for k in keep if k in f}
        trimmed["seed"] = True
        entries.append({"Source": a.seed_source, "DetailType": "Security Hub Findings - Imported",
                        "Resources": [r["Id"] for r in f.get("Resources", []) if r.get("Id", "").startswith("arn:")][:5],
                        "Detail": json.dumps({"findings": [trimmed]})})
    rep.log(f"Security Hub: {len(entries)} RDS.* findings to seed from {a.securityhub_region} ({'FAILED+PASSED' if a.include_passed else 'FAILED only'})",
            securityhub_seed_candidates=len(entries))
    return entries


def seed_trusted_advisor(aws, rep, a):
    checks = aws.run("support", "describe-trusted-advisor-checks", "--language", "en", region="us-east-1")["checks"]
    rds_checks = [c for c in checks if "RDS" in c["name"] or "Aurora" in c["name"]]
    status_map = {"warning": "WARN", "error": "ERROR", "ok": "OK", "not_available": "INFO"}
    entries, checked = [], 0
    # Summaries are one call per 100 checks and tell us which checks flag anything at all; only those
    # need the (slow, throttled) per-check result call. Keep concurrency low - the Support API throttles.
    flagged_ids = set()
    ids = [c["id"] for c in rds_checks]
    for i in range(0, len(ids), 100):
        summ, _ = aws.try_run("support", "describe-trusted-advisor-check-summaries", "--check-ids", *ids[i:i + 100], region="us-east-1")
        for s in (summ or {}).get("summaries", []):
            if s.get("resourcesSummary", {}).get("resourcesFlagged", 0) > 0 or (a.include_passed and s.get("resourcesSummary", {}).get("resourcesProcessed", 0) > 0):
                flagged_ids.add(s["checkId"])
    todo = [c for c in rds_checks if c["id"] in flagged_ids]
    rep.log(f"Trusted Advisor: {len(rds_checks)} RDS/Aurora checks, {len(todo)} with flagged resources to read")
    with ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(lambda c: (c, aws.try_run("support", "describe-trusted-advisor-check-result", "--check-id", c["id"],
                                                            "--language", "en", region="us-east-1")[0]), todo))
    for c, res in results:
        if not res:
            continue
        checked += 1
        for fr in res["result"].get("flaggedResources", []):
            status = status_map.get(fr.get("status"), "INFO")
            if status not in ("WARN", "ERROR") and not a.include_passed:
                continue
            meta = dict(zip(c.get("metadata", []), fr.get("metadata", [])))
            arn = next((m for m in fr.get("metadata", []) if isinstance(m, str) and m.startswith("arn:")), None)
            detail = {"check-name": c["name"], "check-item-detail": meta, "status": status,
                      "resource_id": arn or fr.get("resourceId"), "uuid": fr.get("resourceId"), "seed": True}
            entries.append({"Source": a.seed_source, "DetailType": "Trusted Advisor Check Item Refresh Notification",
                            "Resources": [arn] if arn else [], "Detail": json.dumps(detail)})
    rep.log(f"Trusted Advisor: {checked} check results read, {len(entries)} flagged items to seed", ta_seed_candidates=len(entries))
    return entries


def cmd_seed(a):
    aws, rep = Aws(a.profile, a.region), Report(a.out)
    bus = resolve_bus_arn(aws, a)
    entries = []
    if "securityhub" in a.sources:
        entries += seed_securityhub(aws, rep, a)
    if "trustedadvisor" in a.sources:
        entries += seed_trusted_advisor(aws, rep, a)
    for e in entries:
        e["EventBusName"] = bus
    if a.dry_run:
        rep.log(f"dry run - {len(entries)} events prepared, none sent")
        return 0
    sent, failed = put_events(aws, entries)
    (rep.log if not failed else rep.fail)(f"seeded {sent} events onto {bus} ({failed} failed)", seeded=sent, seed_failed=failed)
    rep.log("the dashboard tables now start from the current state; live events supersede seeded ones per resource")
    return 0 if rep.ok else 1


def cmd_inject_test_events(a):
    aws, rep = Aws(a.profile, a.region), Report(a.out)
    account = aws.account()
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    entries = []
    for path in sorted(FIXTURES.glob("*.json")):
        text = path.read_text().replace("{{ACCOUNT}}", account).replace("{{REGION}}", a.region).replace("{{TIME}}", now).replace("{{UUID}}", str(uuid.uuid4()))
        fx = json.loads(text)
        entry = {"Source": a.seed_source, "DetailType": fx["detail-type"], "Detail": json.dumps(fx["detail"]),
                 "Resources": fx.get("resources", [])}
        if a.bus == "central":
            entry["EventBusName"] = resolve_bus_arn(aws, a)
        entries.append(entry)
        rep.log(f"prepared {path.name} -> {fx['detail-type']}")
    t0 = int(time.time() * 1000) - 5000
    sent, failed = put_events(aws, entries)
    (rep.log if not failed else rep.fail)(f"put {sent} test events on the {a.bus} bus ({failed} failed)", injected=sent)
    if a.wait <= 0:
        rep.log("delivery not checked (--wait 0); run verify in a minute")
        return 0 if rep.ok else 1
    # Prove delivery: the events must show up in the central log group. Rules created seconds ago can
    # still be propagating and silently miss events, so a short count here beats a puzzling empty widget.
    rep.log(f"waiting {a.wait} s, then counting {a.seed_source} events in {a.log_group_name}")
    time.sleep(a.wait)
    got = aws.run("logs", "filter-log-events", "--log-group-name", a.log_group_name, "--start-time", str(t0),
                  "--filter-pattern", f'{{ $.source = "{a.seed_source}" }}', "--limit", "50").get("events", [])
    if len(got) >= sent:
        rep.log(f"delivered: {len(got)} events in {a.log_group_name} - run verify to see them in every widget", delivered=len(got))
    else:
        rep.fail(f"only {len(got)} of {sent} events reached {a.log_group_name}. Rules deployed less than a minute ago may not be active yet - "
                 f"re-run inject-test-events; if it persists, check AWS/Events FailedInvocations for the rds-posture rules", delivered=len(got))
    return 0 if rep.ok else 1


def cmd_verify(a):
    aws, rep = Aws(a.profile, a.region), Report(a.out)
    account = aws.account()
    regions = [rg.strip() for rg in a.member_regions.split(",")]
    rep.log(f"verifying in {account} / {a.region} ({a.iac}), last {a.hours} h")
    if a.iac == "terraform":
        tf = Terraform(aws)
        for module, rg in [("central", a.region)] + [("member", rg) for rg in regions]:
            try:
                tf.select(module, rg, create=False)
                n = tf.state_count(module, rg)
            except RuntimeError as e:
                n, rg = 0, f"{rg} ({str(e)[-160:]})"
            (rep.log if n else rep.fail)(f"terraform {module} state, workspace {rg}: {n} resources")
    else:
        st, _ = stack_status(aws, a.central_stack_name)
        (rep.log if st and st.endswith("_COMPLETE") and "ROLLBACK" not in st else rep.fail)(f"central stack: {st}")
        for rg in regions:
            st_m, _ = stack_status(aws, a.member_stack_name, rg)
            (rep.log if st_m and st_m.endswith("_COMPLETE") and "ROLLBACK" not in st_m else rep.fail)(f"member stack in {rg}: {st_m}")

    # Resource-level checks, independent of the toolchain that created them.
    bus, err = aws.try_run("events", "describe-event-bus", "--name", a.bus_name)
    (rep.log if bus else rep.fail)(f"central bus {a.bus_name}: {'present' if bus else err}")
    rules = aws.run("events", "list-rules", "--event-bus-name", a.bus_name).get("Rules", []) if bus else []
    (rep.log if len(rules) == CENTRAL_RULES else rep.fail)(f"rules on the central bus: {len(rules)} (expected {CENTRAL_RULES})")
    flt, err = aws.try_run("logs", "describe-metric-filters", "--log-group-name", a.log_group_name)
    if flt is None:
        rep.fail(f"log group {a.log_group_name}: {err}")
    else:
        filters = flt.get("metricFilters", [])
        (rep.log if len(filters) == METRIC_FILTERS else rep.fail)(f"metric filters on {a.log_group_name}: {len(filters)} (expected {METRIC_FILTERS})")
    for rg in regions:
        fwd = aws.run("events", "list-rules", "--name-prefix", "rds-posture-fwd-", region=rg).get("Rules", [])
        # Security Hub and Health rules are optional (EnableSecurityHubRule / EnableHealthRule).
        (rep.log if MEMBER_RULES - 2 <= len(fwd) <= MEMBER_RULES else rep.fail)(
            f"member forwarding rules in {rg}: {len(fwd)} (expected {MEMBER_RULES}, or fewer with feed rules disabled)")

    try:
        status, rows = logs_query(aws, "stats count(*) as n by `source`, `detail-type` | sort n desc", a.hours, log_group=a.log_group_name)
        rep.log(f"events by source/type: {rows}", events=rows)
        if not rows:
            rep.log("   no events yet - inject-test-events, seed, or wait for the next Trusted Advisor / Security Hub refresh")
    except Exception as e:  # noqa: BLE001
        rep.fail(f"events-by-source query on {a.log_group_name}: {str(e)[-200:]}")

    mets = aws.run("cloudwatch", "list-metrics", "--namespace", NAMESPACE).get("Metrics", [])
    rep.log(f"{len(mets)} metrics in {NAMESPACE}", metrics=len(mets))

    alarms = aws.run("cloudwatch", "describe-alarms", "--alarm-name-prefix", "rds-posture-").get("MetricAlarms", [])
    for al in alarms:
        hist = aws.run("cloudwatch", "describe-alarm-history", "--alarm-name", al["AlarmName"], "--history-item-type", "StateUpdate", "--max-records", "3")
        last = [h["HistorySummary"] for h in hist.get("AlarmHistoryItems", [])][:3]
        rep.log(f"alarm {al['AlarmName']}: {al['StateValue']} (recent: {last})")

    dash, err = aws.try_run("cloudwatch", "get-dashboard", "--dashboard-name", a.dashboard_name)
    if dash is None:
        rep.fail(f"dashboard {a.dashboard_name}: {err}")
    else:
        widgets = json.loads(dash["DashboardBody"]).get("widgets", [])
        rep.log(f"dashboard {a.dashboard_name}: {len(widgets)} widgets")
        for w in widgets:
            if w["type"] != "log":
                continue
            title = w["properties"]["title"]
            try:
                status, rows = logs_query(aws, w["properties"]["query"], a.hours, limit=50, log_group=a.log_group_name)
            except Exception as e:  # noqa: BLE001
                status, rows = f"error {str(e)[-200:]}", []
            (rep.log if status == "Complete" else rep.fail)(f"widget query '{title[:70]}': {status}, {len(rows)} rows")
            if status == "Complete" and title.startswith("Failing RDS resources - Security Hub detail"):
                enriched = sum(1 for row in rows if row.get("engine") and row.get("engineVersion"))
                rep.log(f"  Security Hub engine/version: {enriched}/{len(rows)} rows populated (source-native ASFF details)",
                        securityhub_engine_version_rows=enriched,
                        securityhub_detail_rows=len(rows))
    rep.log("verify " + ("PASSED" if rep.ok else "FAILED"))
    return 0 if rep.ok else 1


def cmd_capture(a):
    aws, rep = Aws(a.profile, a.region), Report(a.out)
    account = aws.account()
    out = pathlib.Path(a.dir)
    out.mkdir(parents=True, exist_ok=True)
    body = json.loads(aws.run("cloudwatch", "get-dashboard", "--dashboard-name", a.dashboard_name)["DashboardBody"])
    index = ["# Dashboard captures", "", f"Captured {dt.datetime.now(dt.timezone.utc):%Y-%m-%d %H:%M} UTC, last {a.hours} h. "
             "Account IDs, IAM session and user names, and IP addresses are redacted.", ""]
    for i, w in enumerate(body.get("widgets", [])):
        props = w.get("properties", {})
        title = props.get("title", f"widget-{i}")
        slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")[:60] or f"widget-{i}"
        if w["type"] == "metric":
            widget = {k: props[k] for k in ("metrics", "view", "stacked", "stat", "period", "title") if k in props}
            widget.update({"region": a.region, "width": 1200, "height": 400, "start": f"-PT{max(1, round(a.hours * 60))}M", "end": "PT0H"})
            try:
                img = aws.run("cloudwatch", "get-metric-widget-image", "--metric-widget", json.dumps(widget))["MetricWidgetImage"]
                (out / f"{slug}.png").write_bytes(base64.b64decode(img))
                rep.log(f"png  {slug}.png")
                index.append(f"## {title}\n\n![{title}]({slug}.png)\n")
            except Exception as e:  # noqa: BLE001
                rep.fail(f"metric widget '{title}': {str(e)[-200:]}")
        elif w["type"] == "log":
            status, rows = logs_query(aws, props["query"], a.hours, limit=a.rows, log_group=a.log_group_name)
            if status != "Complete":
                rep.fail(f"log widget '{title}': {status}")
                continue
            cols = [c for c in (rows[0].keys() if rows else []) if c not in ("@ptr",)]
            md = [f"## {title}", "", f"{len(rows)} rows", ""]
            if rows:
                md += ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
                for r in rows:
                    md.append("| " + " | ".join(redact(str(r.get(c, "")), account).replace("|", "\\|") for c in cols) + " |")
            (out / f"{slug}.md").write_text("\n".join(md) + "\n")
            rep.log(f"table {slug}.md ({len(rows)} rows)")
            index.append(f"## {title}\n\nSee [{slug}.md]({slug}.md) ({len(rows)} rows).\n")
    (out / "README.md").write_text("\n".join(index) + "\n")
    rep.log(f"index written to {out / 'README.md'}")
    return 0 if rep.ok else 1


def cmd_destroy(a):
    aws, rep = Aws(a.profile, a.region), Report(a.out)
    regions = [rg.strip() for rg in a.member_regions.split(",")]
    if a.iac == "terraform":
        tf = Terraform(aws)
        bus = resolve_bus_arn(aws, a)  # destroy still has to satisfy the required variable
        for rg in regions:
            tf.destroy(rep, "member", rg, {"central_bus_arn": bus, "seed_event_source": a.seed_source})
        tf.destroy(rep, "central", a.region, {"bus_name": a.bus_name, "dashboard_name": a.dashboard_name})
        return 0 if rep.ok else 1
    def delete_stack(name, region=None):
        aws.try_run("cloudformation", "delete-stack", "--stack-name", name, region=region, expect_json=False)
        aws.try_run("cloudformation", "wait", "stack-delete-complete", "--stack-name", name, region=region, expect_json=False, timeout=900)
        st, _ = stack_status(aws, name, region)
        if st is None:
            rep.log(f"deleted {name} in {region or a.region}")
        else:
            rep.fail(f"stack {name} in {region or a.region} still {st} after delete")
            for f in stack_failures(aws, name, region):
                rep.log("   " + f)

    for rg in regions:
        delete_stack(a.member_stack_name, rg)
    delete_stack(a.central_stack_name)
    return 0 if rep.ok else 1

# ----------------------------------------------------------------------------- argument parsing

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--profile", help="AWS CLI profile (default: environment)")
    p.add_argument("--region", default="us-east-1", help="central Region (Trusted Advisor emits in us-east-1)")
    p.add_argument("--iac", choices=["cloudformation", "terraform"], default="cloudformation",
                   help="toolchain for deploy-central / deploy-member / destroy, and how verify finds the deployment")
    p.add_argument("--bus-name", default=BUS_NAME, help="central event bus name")
    p.add_argument("--log-group-name", default=LOG_GROUP, help="central log group (match the deployment's log_group_name)")
    p.add_argument("--dashboard-name", default=DASHBOARD, help="dashboard name (account-wide; use a distinct one per deployment)")
    p.add_argument("--out", help="also write a JSON report to this path")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("preflight"); s.set_defaults(fn=cmd_preflight)

    s = sub.add_parser("deploy-central"); s.set_defaults(fn=cmd_deploy_central)
    s.add_argument("--stack-name", default=CENTRAL_STACK)
    s.add_argument("--org-ids", help="comma-separated organization IDs allowed to PutEvents (multi-Org)")
    s.add_argument("--alarm-email")
    s.add_argument("--metric-statuses", choices=["failed-only", "all"])
    s.add_argument("--log-retention-days")
    s.add_argument("--seed-source")

    for name, fn in (("deploy-member", cmd_deploy_member), ("stackset-commands", cmd_stackset_commands), ("seed", cmd_seed),
                     ("inject-test-events", cmd_inject_test_events), ("verify", cmd_verify), ("capture", cmd_capture), ("destroy", cmd_destroy)):
        s = sub.add_parser(name); s.set_defaults(fn=fn)
        s.add_argument("--central-stack-name", default=CENTRAL_STACK)
        s.add_argument("--central-bus-arn", help="defaults to the EventBusArn output of the central stack")
        s.add_argument("--seed-source", default="rds-posture.seed")
        if name in ("deploy-member", "verify", "destroy"):
            s.add_argument("--member-regions", default="us-east-1", help="comma-separated Regions of this account")
            s.add_argument("--stack-name", "--member-stack-name", dest="member_stack_name" if name != "deploy-member" else "stack_name", default=MEMBER_STACK)
        if name == "stackset-commands":
            s.add_argument("--stackset-name", default="rds-posture-member")
            s.add_argument("--ou-ids", required=True, help="comma-separated OU IDs (or the root ID) to deploy to")
            s.add_argument("--regions", default="us-east-1", help="comma-separated Regions")
            s.add_argument("--delegated-admin", action="store_true")
        if name == "seed":
            s.add_argument("--sources", default="securityhub,trustedadvisor")
            s.add_argument("--securityhub-region", default="us-east-1", help="Security Hub home (aggregation) Region")
            s.add_argument("--include-passed", action="store_true", help="also seed PASSED findings / OK check items")
            s.add_argument("--max-items", type=int, default=20000)
            s.add_argument("--dry-run", action="store_true")
        if name == "inject-test-events":
            s.add_argument("--bus", choices=["default", "central"], default="default", help="default bus exercises the member forwarding rules")
            s.add_argument("--wait", type=int, default=60, help="seconds to wait before confirming the events reached the central log group (0 = skip)")
        if name in ("verify", "capture"):
            s.add_argument("--hours", type=float, default=168, help="lookback hours (default: 168 = 7 days)")
        if name == "capture":
            s.add_argument("--dir", default=str(REPO / "docs" / "images"))
            s.add_argument("--rows", type=int, default=50)
    a = p.parse_args()
    sys.exit(a.fn(a))


if __name__ == "__main__":
    main()
