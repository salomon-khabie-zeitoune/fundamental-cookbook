# CloudFormation Service Role for Fundamental Platform

This directory contains IAM policies and scripts to create a CloudFormation Service Role. This role allows CloudFormation to deploy the Fundamental Platform stack on behalf of users who may not have direct permissions on all underlying AWS resources.
Review each policy file before deployment to ensure it meets your organization's security requirements

## How It Works

When you deploy a CloudFormation stack with a service role (`--role-arn`), CloudFormation **assumes that role** to create resources instead of using the deploying user's permissions. This means:

- The **user** only needs permission to:
  - `cloudformation:CreateStack`, `UpdateStack`, `DeleteStack`
  - `iam:PassRole` for the service role
- The **service role** has permissions for all underlying resources (EC2, VPC, S3, etc.)

## Files

```
cloudformation-deploy-role/
├── trust-policy.json              # Trust policy allowing CloudFormation to assume the role
├── policies/
│   ├── 01-cloudformation-s3.json  # CloudFormation + S3 buckets
│   ├── 02-networking.json         # VPC, Subnets, NAT, IGW, Routes, Endpoints, Security Groups
│   ├── 03-compute.json            # EC2, Launch Templates, ASG, Load Balancers, EKS, helm-deployer Lambda
│   ├── 04-iam.json                # IAM Roles, Instance Profiles, OIDC provider (IRSA), service-linked roles
│   ├── 05-data-services.json      # KMS (incl. grants), Secrets, AmazonMQ, ElastiCache, SSM, CloudWatch Logs
│   └── 06-api-gateway.json        # REST API Gateway, VPC Links
├── create-role.sh                 # Script to create the role
├── delete-role.sh                 # Script to delete the role
└── README.md
```

## Quick Start

### Option 1: Use the Scripts

```bash
# Create the role
./create-role.sh

# Or with a custom name
./create-role.sh MyCompany-FundamentalPlatform-CFRole
```

### Option 2: Manual AWS CLI

The combined permission set exceeds the 10,240-char limit for inline role policies, so each file is created as a **customer-managed policy** (separate 6 KB limit each) and attached to the role - the same approach `create-role.sh` uses. Do not attach them as inline policies.

```bash
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# 1. Create the role
aws iam create-role \
  --role-name FundamentalPlatform-CFServiceRole \
  --assume-role-policy-document file://trust-policy.json \
  --description "CloudFormation service role for Fundamental Platform"

# 2. Create one customer-managed policy per file and attach it.
#    The policy name follows create-role.sh: <role>-<area>, where <area>
#    is the file name without its NN- prefix (e.g. 01-cloudformation-s3.json
#    -> FundamentalPlatform-CFServiceRole-cloudformation-s3).
for policy_file in policies/*.json; do
  area="$(basename "$policy_file" .json | sed 's/^[0-9]*-//')"
  policy_name="FundamentalPlatform-CFServiceRole-${area}"

  aws iam create-policy \
    --policy-name "$policy_name" \
    --policy-document "file://$policy_file"

  aws iam attach-role-policy \
    --role-name FundamentalPlatform-CFServiceRole \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${policy_name}"
done
```

### Option 3: AWS Console

1. Go to **IAM → Policies → Create policy** and, for each file in `policies/`, paste its JSON and name the policy `FundamentalPlatform-CFServiceRole-<area>` (e.g. `01-cloudformation-s3.json` → `FundamentalPlatform-CFServiceRole-cloudformation-s3`). Use customer-managed policies, not inline - the combined set exceeds the inline-policy size limit.
2. Go to **IAM → Roles → Create role**
3. Select **Custom trust policy** and paste contents of `trust-policy.json`
4. On **Add permissions**, attach the customer-managed policies you created in step 1
5. Name the role (e.g., `FundamentalPlatform-CFServiceRole`)

## Deploying the Stack with the Service Role

Once the role is created, deploy the Fundamental Platform stack:

```bash
aws cloudformation create-stack \
  --stack-name my-fundamental-deployment \
  --template-url https://ec2-marketplace-cloudformation-templates.s3.us-west-1.amazonaws.com/<version>/templates/root-template.yaml \
  --role-arn arn:aws:iam::<account-id>:role/FundamentalPlatform-CFServiceRole \
  --parameters \
    ParameterKey=DeploymentName,ParameterValue=my-deployment \
    ParameterKey=AmiId,ParameterValue=ami-xxxxxxxxx \
    ParameterKey=ConsumerVpc1Id,ParameterValue=vpc-xxxxxxxxx \
    ParameterKey=ConsumerVpc1SubnetIds,ParameterValue=subnet-xxx,subnet-yyy
```

## User Permissions Required

The user deploying the stack needs this minimal IAM policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "cloudformation:CreateStack",
        "cloudformation:UpdateStack",
        "cloudformation:DeleteStack",
        "cloudformation:DescribeStacks",
        "cloudformation:DescribeStackEvents",
        "cloudformation:GetTemplate"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::*:role/FundamentalPlatform-CFServiceRole"
    }
  ]
}
```

## Cleanup

To delete the service role:

```bash
./delete-role.sh

# Or with a custom name
./delete-role.sh MyCompany-FundamentalPlatform-CFRole
```
