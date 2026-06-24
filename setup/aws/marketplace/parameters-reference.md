# Parameters Reference

This is the complete reference for the CloudFormation parameters used to deploy the Fundamental Platform (v1.2.0), plus a ready‑to‑edit `params.json` for deploying from the AWS CLI. Most parameters have production‑ready defaults — a 0‑to‑1 deployment only requires the handful in the **Required** group below.

> The Console launch (via the Marketplace subscription) shows these same parameters as a form and pre‑fills version‑pinned values for you. Use this reference if you prefer the **CLI** (`params.json`) path, or to understand any parameter before changing it.

---

## Required parameters (no default — you must supply these)

| Parameter | What it is | How to get the value |
|-----------|-----------|----------------------|
| `AmiId` | The platform AMI used by all three EC2 compute tiers (API, ModelCPU, ModelGPU). | Fundamental shares this AMI with your account (launch permission), one per region. The Console Launch page pre‑fills it for the region you pick; for a CLI deploy, copy that value from the Launch page or ask Fundamental for the AMI ID in your region. |
| `CloudFormationExecutionRoleArn` | The IAM role CloudFormation runs as. The stack also grants this role **EKS cluster‑admin** so it can bootstrap the cluster's access entries. | The `FundamentalPlatform-CFServiceRole` ARN from `create-role.sh` — pass the **same** ARN as `--role-arn` (Console: the **Permissions** field). |
| `ConsumerVpc1Id` | The VPC where your client applications run and call the private API from. **At least one Consumer VPC is required.** | An existing VPC in your account, or create a minimal one (see the Deployment Guide → Networking). |
| `ConsumerVpc1SubnetIds` | Comma‑separated subnet IDs in that VPC that receive the API endpoint. | Subnets in `ConsumerVpc1Id`. No internet egress required. |

> **`CloudFormationExecutionRoleArn` vs `EksAdminRoleArn`:** keep them **different** roles. `CloudFormationExecutionRoleArn` is the deploy role (gets cluster‑admin automatically as the cluster creator). `EksAdminRoleArn` is an *optional, separate* human/SSO role for `kubectl`. Setting both to the same ARN makes the stack try to create a duplicate EKS access entry and fail.

---

## Strongly recommended

| Parameter | Default | Notes |
|-----------|---------|-------|
| `DeploymentName` | `fundamental` | Prefixes resource and S3 bucket names. **Max 19 characters** — it is embedded in S3 bucket names like `<name>-nexus-trained-models-<region>-<account>`, which must stay within the 63‑char S3 limit. Use a fresh name for a delete‑and‑recreate (the trained‑model bucket is retained). |
| `EksAdminRoleArn` | *(empty)* | Optional IAM role granted `kubectl` cluster‑admin via an EKS access entry. Leave empty if you don't need direct cluster access (not required to use the platform). Access is private‑endpoint only — must originate inside the platform VPC. |

---

## Networking

| Parameter | Default | Notes |
|-----------|---------|-------|
| `ExistingVpcId` | *(empty)* | Leave empty to let the stack create the platform VPC. Set to deploy into a VPC you control (then the six `ExistingPrivate*` params below are required). |
| `ExistingPrivateSubnet1Id` / `…2Id` | *(empty)* | Two private subnets in two AZs (required if `ExistingVpcId` is set). |
| `ExistingPrivateRouteTable1Id` / `…2Id` | *(empty)* | One route table per subnet. |
| `ExistingPrivateSubnet1Az` / `…2Az` | *(empty)* | AZ names, e.g. `us-west-1a`, `us-west-1b`. |
| `VpcCidr` | `10.0.0.0/16` | Platform VPC CIDR (must match when bringing an existing VPC). |
| `PrivateSubnet1Cidr` / `…2Cidr` | `10.0.11.0/24` / `10.0.12.0/24` | Used only when creating a new VPC. |
| `ConsumerVpc2Id`…`ConsumerVpc5Id` (+ `*SubnetIds`) | *(empty)* | Up to four additional consumer VPCs. |
| `CreateVpcEndpoints` | `true` | Master toggle for all VPC endpoints. Set `false` only if you have already provisioned them in your VPC. |
| `CreateEndpoint*` (S3, Kms, ExecuteApi, Monitoring, Logs, Ssm, SsmMessages, Ec2Messages, SecretsManager, Sts, MeteringMarketplace) | `true` | Per‑service endpoint toggles. Leave on unless an endpoint already exists. |

---

## Compute tiers (EC2)

| Parameter | Default | Notes |
|-----------|---------|-------|
| `ApiInstanceType` | `m7i.4xlarge` | API tier. |
| `ApiDesiredCapacity` | `1` | API instance count. |
| `ModelCpuInstanceType` | `c7i.48xlarge` | CPU model tier. |
| `ModelCpuDesiredCapacity` | `1` | |
| `ModelGpuInstanceType` | `p5en.48xlarge` | GPU inference tier. |
| `ModelGpuDesiredCapacity` | `1` | |
| `PreferredAvailabilityZone` | *(empty)* | AZ for GPU Capacity Block (e.g. `us-west-1a`). |
| `CapacityReservationId` | *(empty)* | GPU Capacity Block reservation (e.g. `cr-1234567890abcdef0`). |
| `ApiS3Path` / `ModelCpuS3Path` / `ModelGpuS3Path` | version‑pinned (API tier defaults to `ftm-api-service/0.0.180/`) | Override the artifact version per tier. Leave at the pinned default to use the versions shipped in this release. |

---

## EKS

| Parameter | Default | Notes |
|-----------|---------|-------|
| `EksNodeInstanceType` | `m7i.4xlarge` | Worker node type (general‑purpose node groups, one per AZ). |
| `EksNodeDesiredCapacity` | `1` | Nodes per AZ group. |
| `EksNodeMinCapacity` / `EksNodeMaxCapacity` | `1` / `1` | Auto Scaling bounds. |
| `EksNodeRootVolumeSize` | `100` | Root EBS GiB per node. |
| `EnableEksHeavyNodeGroup` | `true` | Add the dedicated heavy‑compute node group: a separate, tainted (`dedicated=heavy-compute:NoSchedule`) node reserved for future heavy workloads, in addition to the general worker nodes. Stays empty until a workload tolerates the taint. Set `false` to drop it (saves the reserved node's cost). |
| `EksHeavyNodeInstanceType` | `m7i.4xlarge` | Instance type for the heavy‑compute node. Allowed: `m7i.4xlarge`, `m7i.8xlarge`, `r7i.2xlarge`, `r7i.4xlarge`. |
| `EksHeavyNodeDesiredCapacity` / `EksHeavyNodeMinCapacity` / `EksHeavyNodeMaxCapacity` | `1` / `1` / `1` | Auto Scaling bounds for the heavy‑compute node group. |
| `EksKubernetesVersion` | `1.33` | Control‑plane version. |
| `PrivateEksClusterEndpoint` | `true` | Private‑only API endpoint. |
| `EksServiceIpv4Cidr` | `172.21.0.0/16` | Kubernetes service CIDR. |
| `EksNodeAmiId` | *(empty)* | Optional override; empty uses the EKS‑optimized AMI. |

---

## Images & version (pre‑filled — change only on an upgrade)

These are version‑pinned in each release. The Console Launch page fills them in for you; in `params.json` you can omit them to take the template defaults.

| Parameter | Default | Notes |
|-----------|---------|-------|
| `ImageRegistryUri` | *(empty)* | Empty = the importer loads images into **your own** ECR (`<account>.dkr.ecr.<region>.amazonaws.com/fundamental`) and the platform pulls from there. |
| `SkipImageImport` | `false` | `false` = automatic import (default). `true` only if you loaded the bundle into your ECR yourself first (pre‑scan path — see the Image Bundle Guide). |
| `BundleS3Key` / `CraneS3Key` | version‑pinned | Offline bundle + crane binary S3 keys. Bump on an upgrade to ship new app/chart versions without changing template code. |
| `FunCrdChartVersion` / `FunInfraChartVersion` / `FunAppChartVersion` | `1.1.0` / `1.3.3` / `1.2.0` | Umbrella chart versions. Match the bundle. |
| `HelmDeployerImageTag` | `1.2.2-arm64` | helm‑deployer Lambda image tag (tracks the bundle). |

---

## Logging (optional)

| Parameter | Default | Notes |
|-----------|---------|-------|
| `RsyslogHost` | *(empty)* | Remote syslog server; empty disables forwarding. |
| `RsyslogPort` / `RsyslogProtocol` | `514` / `tcp` | |
| `RsyslogCollectFiles` | *(empty)* | Comma‑separated globs to forward. |
| `RsyslogFilter` | `auth.info;authpriv.info;*.crit` | Facility/severity filter. |

---

## `params.json` template (CLI deploy)

A minimal 0‑to‑1 file — fill the four required values (and `DeploymentName`/`EksAdminRoleArn` if you want). Everything omitted uses the template default.

```json
[
  { "ParameterKey": "DeploymentName",                 "ParameterValue": "fundamental" },
  { "ParameterKey": "AmiId",                          "ParameterValue": "ami-REPLACE_ME" },
  { "ParameterKey": "CloudFormationExecutionRoleArn", "ParameterValue": "arn:aws:iam::<ACCOUNT_ID>:role/FundamentalPlatform-CFServiceRole" },
  { "ParameterKey": "ConsumerVpc1Id",                 "ParameterValue": "vpc-REPLACE_ME" },
  { "ParameterKey": "ConsumerVpc1SubnetIds",          "ParameterValue": "subnet-REPLACE_ME" },
  { "ParameterKey": "EksAdminRoleArn",                "ParameterValue": "arn:aws:iam::<ACCOUNT_ID>:role/<your-kubectl-role>" }
]
```

> To also customize compute/EKS, add the relevant rows from the tables above (e.g. `EksNodeInstanceType`, `ModelGpuInstanceType`, `CapacityReservationId`). Do **not** add `BundleS3Key`/`CraneS3Key`/chart‑version rows unless Fundamental tells you to — the template defaults are correct for this version.

### Deploy command

Get the **template URL** from the Marketplace **Launch CloudFormation** page (it shows the S3 template URL), then:

```bash
aws cloudformation create-stack \
  --stack-name fundamental \
  --region "$DEPLOYMENT_REGION" \
  --template-url "<MARKETPLACE_TEMPLATE_URL>" \
  --parameters file://params.json \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/FundamentalPlatform-CFServiceRole
```

Pass the `FundamentalPlatform-CFServiceRole` ARN as `--role-arn` and set `CloudFormationExecutionRoleArn` (in `params.json`) to the **same** ARN. Deploying with the service role (rather than as a plain admin) is what keeps the EKS access‑entry bootstrap reliable.

Track progress with:

```bash
aws cloudformation describe-stack-events --stack-name fundamental --region "$DEPLOYMENT_REGION" \
  --query 'StackEvents[?contains(ResourceStatus, `FAILED`)].[LogicalResourceId,ResourceStatusReason]' --output table
```

The deployment takes roughly **45 minutes** (EKS + the image import + the Helm install run sequentially). See the [Deployment Guide](./deployment-guide.md) for verification and connecting your application.
