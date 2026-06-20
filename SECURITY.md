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

### IAM
- IAM roles follow least-privilege with scoped resource ARNs where supported
- Review and tighten `Resource: "*"` statements for actions that do not support resource-level permissions

### Network
- EC2 instances should be deployed in private subnets only
- Security groups should be scoped to specific VPC CIDRs rather than broad RFC1918 ranges

### Instance Metadata
- IMDSv2 is enforced on all EC2 instances (`http_tokens = "required"`)

### SQL Server Scripts
- PowerShell scripts under `module/ec2_sql_aoag/scripts/` use string interpolation patterns such as `${variable}` and `$($expression)` for dynamic configuration
- Static analysis tools (e.g., detect-secrets) may flag these as false positives for embedded credentials
- All actual secrets are retrieved at runtime from AWS Secrets Manager via SSM parameters — no credentials are hardcoded in script files

### KMS Key Policy
- The KMS key policy includes a `kms:*` statement scoped to the account root principal (`arn:aws:iam::<account-id>:root`)
- This is the [AWS-recommended default key policy](https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-default.html) that delegates permission management to IAM
- It does not grant direct access to any user or role — IAM policies must still explicitly allow KMS actions
- Checkov skip annotation `CKV_AWS_33` documents this pattern in `kms.tf`

### Terraform State
- Use remote state storage (S3 + DynamoDB) for production deployments
- Never commit `terraform.tfstate` files to version control
- The `.gitignore` excludes `*.tfstate` and `*.tfvars` by default

## Vulnerability Reporting

If you discover a potential security issue in this project, we ask that you notify AWS/Amazon Security via our [vulnerability reporting page](http://aws.amazon.com/security/vulnerability-reporting/). Please do **not** create a public GitHub issue.

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.
