# AWS services for security, audit and lineage (opt-in)

The migration skills work **without any AWS resource**. Audit records, lineage events, guardrail
results and archives go to the local store under `logs/` (`services.py status` shows that). This
page lists what to create when you want them in AWS. **Run these commands yourself, after review.**
The agent only reads AWS (steering rule S-7, guard rule GRD-05). Replace
`123456789012`, `us-east-1` and names to suit your account.

Every command was checked against AWS CLI v2 (`aws <service> <operation> help`). Costs apply
(CloudWatch Logs ingestion and storage, Bedrock Guardrails per text unit, S3 storage, KMS
requests, DataZone).

## 0. Do not use root credentials

The migration tools need only the permissions in section 7. Use an IAM Identity Center user or an
IAM role (for example `aws configure sso`, or a role you assume), not root access keys. Check:

```bash
aws sts get-caller-identity --query Arn --output text   # must not end in :root
```

## 1. Audit trail → Amazon CloudWatch Logs

```bash
aws kms create-key --description "kiro-sql-migration logs and archive" --query KeyMetadata.Arn --output text
aws kms create-alias --alias-name alias/kiro-sql-migration --target-key-id <key-arn>
# the key policy must allow the service principal logs.us-east-1.amazonaws.com (kms:Encrypt*, kms:Decrypt*,
# kms:ReEncrypt*, kms:GenerateDataKey*, kms:Describe*) with an aws:logs:arn encryption context condition
aws logs create-log-group --log-group-name /kiro/sql-migration/audit --kms-key-id <key-arn> --deletion-protection-enabled
aws logs put-retention-policy --log-group-name /kiro/sql-migration/audit --retention-in-days 400
aws logs put-data-protection-policy --log-group-identifier /kiro/sql-migration/audit --policy-document file://dp.json
```

`dp.json` masks credentials that slipped past local redaction. It is a second line of defence,
and redaction in `audit.py` stays on:

```json
{"Name": "kiro-sql-migration", "Version": "2021-06-01", "Statement": [
  {"Sid": "audit", "DataIdentifier": ["arn:aws:dataprotection::aws:data-identifier/AwsSecretKey",
     "arn:aws:dataprotection::aws:data-identifier/OpenSshPrivateKey", "arn:aws:dataprotection::aws:data-identifier/PkcsPrivateKey"],
   "Operation": {"Audit": {"FindingsDestination": {}}}},
  {"Sid": "redact", "DataIdentifier": ["arn:aws:dataprotection::aws:data-identifier/AwsSecretKey",
     "arn:aws:dataprotection::aws:data-identifier/OpenSshPrivateKey", "arn:aws:dataprotection::aws:data-identifier/PkcsPrivateKey"],
   "Operation": {"Deidentify": {"MaskConfig": {}}}}]}
```

Config: `"audit": {"cloudwatch": {"log_group": "/kiro/sql-migration/audit"}}`. The tools ship with
`services.py sync`, which `run_tests.sh`, `kiro_migrate.sh` and the agent's `stop` hook call.
Limits handled for you: at most 1,048,576 bytes per batch (26 bytes overhead per event), 10,000
events, a 24-hour span, chronological order, and nothing older than 14 days. Shipping is
at-least-once, so `seq` and `hash` identify duplicates.

**CloudWatch Logs Insights queries** (log group `/kiro/sql-migration/audit`):

```text
# everything one run did, in order
fields @timestamp, severity_text, event, resource.`service.name`, body
| filter run_id = "<32-hex run id>" | sort @timestamp asc

# guardrail blocks and security refusals
fields @timestamp, run_id, event, attributes.rule, attributes.tool_name, body
| filter event in ["guard.blocked", "security.refused", "pgtest.refused", "security.finding"] | sort @timestamp desc

# lineage of one Informatica attribute
fields @timestamp, run_id, attributes.folder, attributes.object, attributes.instance, attributes.attribute, attributes.source_sha256, attributes.converted_sha256
| filter event = "infa.inject.attribute" and attributes.instance = "SQ_Orders"

# slow or failed steps
fields @timestamp, event, attributes.duration_ms, attributes.status, attributes.exit_code
| filter event like /\.end$/ and (attributes.status != "ok" or attributes.duration_ms > 60000)
```

## 2. Prompt-attack guardrail → Amazon Bedrock Guardrails

```bash
aws bedrock create-guardrail --name kiro-sql-migration \
  --blocked-input-messaging "Blocked by the migration guardrail." --blocked-outputs-messaging "Blocked by the migration guardrail." \
  --content-policy-config '{"filtersConfig":[{"type":"PROMPT_ATTACK","inputStrength":"HIGH","outputStrength":"NONE"}]}' \
  --sensitive-information-policy-config '{"piiEntitiesConfig":[{"type":"AWS_ACCESS_KEY","action":"ANONYMIZE"},{"type":"AWS_SECRET_KEY","action":"ANONYMIZE"},{"type":"PASSWORD","action":"ANONYMIZE"}]}' \
  --kms-key-id <key-arn> --query guardrailId --output text
aws bedrock create-guardrail-version --guardrail-identifier <guardrail-id> --description "v1"
```

Config: `"guardrail": {"bedrock": {"guardrail_identifier": "<guardrail-id>", "guardrail_version": "1"}}`.
`services.py guardrail <files>` sends text to `ApplyGuardrail` with `source=INPUT`, in chunks
(`max_chars_per_call`) and within a per-run budget (`max_chars_per_run`). It always runs the local
scan as well. Findings are `SEC-13`, and the sensitive value (`match`) is never stored.

## 3. Evidence archive → Amazon S3 with Object Lock

```bash
aws s3api create-bucket --bucket kiro-sql-migration-archive-123456789012 --object-lock-enabled-for-bucket
aws s3api put-public-access-block --bucket kiro-sql-migration-archive-123456789012 \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket kiro-sql-migration-archive-123456789012 \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms","KMSMasterKeyID":"alias/kiro-sql-migration"},"BucketKeyEnabled":true}]}'
aws s3api put-object-lock-configuration --bucket kiro-sql-migration-archive-123456789012 \
  --object-lock-configuration '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"GOVERNANCE","Days":365}}}'
```

Outside us-east-1, add `--create-bucket-configuration LocationConstraint=<region>` to
`create-bucket`. Config: `"archive": {"s3": {"bucket": "...", "object_lock_mode": "GOVERNANCE",
"retention_days": 365, "kms_key_id": "alias/kiro-sql-migration"}}`. `COMPLIANCE` mode cannot be
shortened or removed by anyone, including root. Choose it only when required.

## 4. Lineage → Amazon DataZone

Create a domain in the console (Amazon DataZone, or Amazon SageMaker Unified Studio for V2
domains), or with the CLI and an existing domain execution role:

```bash
aws datazone create-domain --name kiro-sql-migration \
  --domain-execution-role arn:aws:iam::123456789012:role/service-role/AmazonDataZoneDomainExecution \
  --kms-key-identifier <key-arn> --query id --output text
```

Config: `"lineage": {"datazone": {"domain_identifier": "dzd_..."}}`. `infa_sql_tool.py inject` emits
an OpenLineage `RunEvent`. The job namespace is `informatica://<repository>`, and the inputs are
the source XML and the SQL Server tables. The outputs are the converted XML and the PostgreSQL
tables (namespace from `MIGRATION_LINEAGE_PG_NAMESPACE`, or `postgres://$PGHOST:5432`). The
`kiro_migration` run facet carries the run id and SHA-256 hashes. Events larger than 300,000
bytes are refused. `--client-token` makes retries idempotent.

## 5. Database credentials → AWS Secrets Manager (only when IAM authentication is not possible)

Aurora IAM database authentication (`PG_IAM_AUTH=1`, 15-minute tokens) is preferred and needs no
secret. For other targets:

```bash
aws secretsmanager create-secret --name kiro-sql-migration/test-db --kms-key-id alias/kiro-sql-migration \
  --secret-string file://secret.json      # {"username": "...", "password": "...", "host": "...", "port": 5432, "dbname": "..._test"}
rm -P secret.json
```

Config: `"secrets": {"backend": "auto", "secretsmanager": {"secret_id": "kiro-sql-migration/test-db"}}`.
Run tests with `PG_SECRET_FROM_SERVICES=1 bash supporting-files/run_tests.sh --project`, or
`python3 .kiro/skills/sql-conversion/scripts/migkit/services.py exec -- bash supporting-files/run_tests.sh`.

## 6. Database-side audit → pgaudit and PostgreSQL logs on Aurora

The default parameter group cannot be changed. Create a custom cluster parameter group, attach
it, export the PostgreSQL log, then reboot the writer:

```bash
aws rds create-db-cluster-parameter-group --db-cluster-parameter-group-name kiro-mig-apg17 \
  --db-parameter-group-family aurora-postgresql17 --description "pgaudit + application_name in logs"
aws rds modify-db-cluster-parameter-group --db-cluster-parameter-group-name kiro-mig-apg17 --parameters \
  "ParameterName=shared_preload_libraries,ParameterValue='pg_stat_statements,pgaudit',ApplyMethod=pending-reboot" \
  "ParameterName=pgaudit.log,ParameterValue='ddl,role',ApplyMethod=immediate" \
  "ParameterName=pgaudit.log_parameter,ParameterValue=0,ApplyMethod=immediate" \
  "ParameterName=log_line_prefix,ParameterValue='%t:%r:%u@%d:[%p]:%a:',ApplyMethod=immediate"
aws rds modify-db-cluster --db-cluster-identifier database-1 --db-cluster-parameter-group-name kiro-mig-apg17 \
  --cloudwatch-logs-export-configuration '{"EnableLogTypes":["postgresql"]}' --apply-immediately
aws rds reboot-db-instance --db-instance-identifier <writer-instance-id>
```

Then, as an administrator in the database, run `CREATE EXTENSION pgaudit;`. `%a` prints
`application_name`, which the test engine sets to `mig:<manifest>:<run8>`, so a CloudWatch
search for the first 8 characters of a run id finds its SQL. Keep `pgaudit.log_parameter` off, or
bind values (possibly personal data) reach the logs. Database Activity Streams are not supported
on Aurora Serverless v2 instances.

## 7. Least-privilege IAM policy for the migration tools

Attach this to the role the developer or CI uses. Remove statements for services you do not use.
The tools never create or delete resources.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid": "AuditLogs", "Effect": "Allow", "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
     "Resource": "arn:aws:logs:us-east-1:123456789012:log-group:/kiro/sql-migration/audit:*"},
    {"Sid": "AuditLogsProbe", "Effect": "Allow", "Action": ["logs:DescribeLogGroups"], "Resource": "*"},
    {"Sid": "Lineage", "Effect": "Allow", "Action": ["datazone:GetDomain", "datazone:PostLineageEvent"],
     "Resource": "arn:aws:datazone:us-east-1:123456789012:domain/dzd_xxxxxxxxxxxx"},
    {"Sid": "Guardrail", "Effect": "Allow", "Action": ["bedrock:GetGuardrail", "bedrock:ApplyGuardrail"],
     "Resource": "arn:aws:bedrock:us-east-1:123456789012:guardrail/xxxxxxxxxxxx"},
    {"Sid": "Archive", "Effect": "Allow", "Action": ["s3:PutObject", "s3:PutObjectRetention"],
     "Resource": "arn:aws:s3:::kiro-sql-migration-archive-123456789012/kiro-sql-migration/*"},
    {"Sid": "ArchiveProbe", "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::kiro-sql-migration-archive-123456789012"},
    {"Sid": "Kms", "Effect": "Allow", "Action": ["kms:GenerateDataKey", "kms:Decrypt"],
     "Resource": "arn:aws:kms:us-east-1:123456789012:key/<key-id>"},
    {"Sid": "Secret", "Effect": "Allow", "Action": ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"],
     "Resource": "arn:aws:secretsmanager:us-east-1:123456789012:secret:kiro-sql-migration/test-db-*"},
    {"Sid": "TestDbIamAuth", "Effect": "Allow", "Action": ["rds-db:connect"],
     "Resource": "arn:aws:rds-db:us-east-1:123456789012:dbuser:<cluster-resource-id>/migration_agent"}
  ]
}
```

## 8. Account activity → AWS CloudTrail

CloudTrail event history keeps 90 days of management events without a trail. It covers every
`generate-db-auth-token`, `GetSecretValue` or guardrail call. Look up one:

```bash
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=GetSecretValue --max-results 20
```

For longer retention, create a multi-region trail to an S3 bucket that has a CloudTrail bucket
policy:
`aws cloudtrail create-trail --name kiro-sql-migration --s3-bucket-name <trail-bucket> --is-multi-region-trail --enable-log-file-validation`,
then `aws cloudtrail start-logging --name kiro-sql-migration`.

## 9. Verify

```bash
python3 .kiro/skills/sql-conversion/scripts/migkit/services.py probe --refresh   # every concern: aws or local, and why
python3 .kiro/skills/sql-conversion/scripts/migkit/services.py sync
python3 .kiro/skills/sql-conversion/scripts/migkit/audit.py verify                # hash chain of the local files
```

Amazon CodeGuru Security reached end of support on 2025-11-20. Use Amazon Inspector code
scanning or Amazon Q Developer security scans instead for repository scanning.
