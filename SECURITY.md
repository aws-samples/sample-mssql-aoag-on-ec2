# Security

Note: this asset represents a proof-of-value for the services included and is not intended as a production-ready solution. You must determine how the [AWS Shared Responsibility Model](https://aws.amazon.com/compliance/shared-responsibility-model/) applies to your specific use case and implement the needed controls to achieve your desired security outcomes.

## Security Considerations

### Secrets Management
- All credentials (domain admin, SQL service account) are stored in AWS Secrets Manager
- Never commit `terraform.auto.tfvars` with real values to version control

### Encryption
- All EBS volumes are encrypted with customer-managed multi-region KMS keys
- KMS key rotation is enabled by default
- DR replica keys are automatically created for cross-region deployments

### IAM (production hardening)
- IAM roles follow least-privilege with scoped resource ARNs where the action supports them.
- The EC2 instance role grants broader access than a single cluster strictly needs, to keep the
  sample deployable without a fixed naming convention. Before production, scope these to your own
  resources:
  - **Secrets Manager**: replace `Resource` on the secrets statement with your cluster's secret
    ARNs, e.g. `arn:aws:secretsmanager:<region>:<account-id>:secret:<your-prefix>-*`, instead of
    `secret:*`.
  - **SSM Parameter Store**: scope `ssm:GetParameter`/`ssm:PutParameter` to a path prefix, e.g.
    `arn:aws:ssm:<region>:<account-id>:parameter/<your-prefix>/*`, instead of `parameter/*`.
  - **Describe/List actions** (`ec2:Describe*`, `ssm:Describe*`/`List*`, CloudWatch metrics) keep
    `Resource: "*"` — these actions do not support resource-level permissions in IAM. This is an
    AWS API limitation, not a misconfiguration.

### Network
- EC2 instances should be deployed in private subnets only
- Security groups should be scoped to specific VPC CIDRs rather than broad RFC1918 ranges

### Instance Metadata
- IMDSv2 is enforced on all EC2 instances (`http_tokens = "required"`)

### Host Firewall
- Windows Firewall is left **enabled** on all nodes. `Configure-AOAGFirewall.ps1` opens only the
  ports AOAG/WSFC require (SQL/listener, mirroring, cluster, WinRM), each scoped to the supplied
  CIDRs (the VPC CIDR by default). This is a deliberate second layer behind the security group.
- For a cross-region DAG deployment, pass the peer VPC CIDR as well, or AG replication on the
  mirroring port will be blocked at the host.
- Do not disable the firewall as a shortcut — narrow the CIDRs instead (e.g. a bastion range for
  the WinRM rule).

### SQL Server Scripts
- PowerShell scripts under `module/ec2_sql_aoag/scripts/` use string interpolation patterns such as `${variable}` and `$($expression)` for dynamic configuration
- Static analysis tools (e.g., detect-secrets) may flag these as false positives for embedded credentials
- All actual secrets are retrieved at runtime from AWS Secrets Manager via SSM parameters — no credentials are hardcoded in script files

### TLS for SQL Server Connections (production hardening)
During initial setup the `Invoke-Sqlcmd` calls set `TrustServerCertificate = $true`, which
keeps the connection encrypted but disables certificate *identity* validation. This is required
during bootstrap because SQL Server only has a self-signed certificate at that point. It leaves
inter-node and client-to-SQL traffic exposed to man-in-the-middle attacks if left unchanged.

Before using this deployment beyond a lab, on every node:
1. Install a CA-issued certificate on each SQL Server instance. The Subject Alternative Names
   must cover both the node's own name and the AG listener name (clients connect via the listener).
2. Configure SQL Server to use that certificate and enable `ForceEncryption`.
3. Ensure every client trusts the issuing CA.
4. Remove `TrustServerCertificate = $true` (or set it to `$false`) in:
   - `module/ec2_sql_aoag/scripts/ag/*.ps1`
   - `module/ssm_documents/proserve_aoag_test_failover.tf`
   - the commands in `MANUAL_AOAG_SETUP.md`
   so that certificate validation applies.

### KMS Key Policy
- The KMS key policy includes a `kms:*` statement scoped to the account root principal (`arn:aws:iam::<account-id>:root`)
- This is the [AWS-recommended default key policy](https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-default.html) that delegates permission management to IAM
- It does not grant direct access to any user or role — IAM policies must still explicitly allow KMS actions
- Checkov skip annotation `CKV_AWS_33` documents this pattern in `kms.tf`
- **Production hardening**: the default policy delegates all key management to IAM in the account.
  For production, split the key policy into a narrow *usage* statement and an *administration*
  statement, and scope the admin statement to a specific deployment or break-glass role ARN
  (e.g. `arn:aws:iam::<account-id>:role/AOAGDeployRole`) rather than the account root. This limits
  who can perform sensitive operations such as `kms:PutKeyPolicy` or `kms:ScheduleKeyDeletion` on
  these keys, per your organization's key-governance model.

### Terraform State
- Use remote state storage (S3 + DynamoDB) for production deployments
- Never commit `terraform.tfstate` files to version control
- The `.gitignore` excludes `*.tfstate` and `*.tfvars` by default

## Vulnerability Reporting

If you discover a potential security issue in this project, we ask that you notify AWS/Amazon Security via our [vulnerability reporting page](http://aws.amazon.com/security/vulnerability-reporting/). Please do **not** create a public GitHub issue.

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.
