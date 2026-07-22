# Parameters Reference

This is the complete CloudFormation parameter reference for Fundamental Platform v2.0.0, including a ready-to-edit `params.json` for AWS CLI deploys. Most parameters have production-ready defaults; a standard deployment only requires the values in the **Required** group below.

> The Marketplace Console launch shows the same parameters as a form and pre-fills version-pinned values. Use this reference for CLI deploys or before changing a non-default parameter.

---

## Required Parameters

| Parameter | What it is | How to get the value |
|-----------|-----------|----------------------|
| `AmiId` | Platform AMI for the EC2 compute tiers. | Fundamental shares this AMI with your account, one per region. The Console Launch page pre-fills it; for CLI deploys, copy it from that page or ask Fundamental for the AMI ID in your region. |
| `CloudFormationExecutionRoleArn` | IAM role CloudFormation runs as. The stack grants this role EKS cluster-admin to bootstrap cluster access entries. | The `FundamentalPlatform-CFServiceRole` ARN from `create-role.sh`. Pass the same ARN as `--role-arn` (Console: **Permissions**). |
| `ConsumerVpc1Id` | The VPC where your client applications run and call the private API from. **At least one Consumer VPC is required.** | An existing VPC in your account, or create a minimal one (see the Deployment Guide → Networking). |
| `ConsumerVpc1SubnetIds` | Comma-separated subnet IDs in that VPC that receive the API endpoint. | Subnets in `ConsumerVpc1Id`. No internet egress required. |

> **`CloudFormationExecutionRoleArn` vs `EksAdminRoleArn`:** keep them as different roles. `CloudFormationExecutionRoleArn` is the deploy role. `EksAdminRoleArn` is an optional human or SSO role for `kubectl`. Reusing the same ARN makes the stack try to create a duplicate EKS access entry and fail.

---

## Strongly Recommended

| Parameter | Default | Notes |
|-----------|---------|-------|
| `DeploymentName` | `fundamental` | Prefixes resource and S3 bucket names. **Max 19 characters** because it is embedded in bucket names like `<name>-nexus-trained-models-<region>-<account>`. |
| `EksAdminRoleArn` | *(empty)* | Optional IAM role granted `kubectl` cluster-admin through an EKS access entry. Leave empty if you do not need direct cluster access. Access must originate inside the platform VPC. |

---

## Networking

| Parameter | Default | Notes |
|-----------|---------|-------|
| `ExistingVpcId` | *(empty)* | Leave empty to let the stack create the platform VPC. Set to deploy into a VPC you control (then the six `ExistingPrivate*` params below are required). |
| `ExistingPrivateSubnet1Id` / `ExistingPrivateSubnet2Id` | *(empty)* | Two private subnets in two AZs. Required when `ExistingVpcId` is set. |
| `ExistingPrivateRouteTable1Id` / `ExistingPrivateRouteTable2Id` | *(empty)* | One route table per subnet. |
| `ExistingPrivateSubnet1Az` / `ExistingPrivateSubnet2Az` | *(empty)* | AZ names, e.g. `us-west-1a`, `us-west-1b`. |
| `VpcCidr` | `10.0.0.0/16` | Platform VPC CIDR (must match when bringing an existing VPC). |
| `PrivateSubnet1Cidr` / `PrivateSubnet2Cidr` | `10.0.11.0/24` / `10.0.12.0/24` | Used only when creating a new VPC. |
| `ConsumerVpc2Id` through `ConsumerVpc5Id` plus subnet IDs | *(empty)* | Up to four additional consumer VPCs. |
| `CreateVpcEndpoints` | `true` | Master toggle for all VPC endpoints. Set `false` only if you have already provisioned them in your VPC. |
| `CreateEndpoint*` (S3, Kms, ExecuteApi, Monitoring, Logs, Ssm, SsmMessages, Ec2Messages, SecretsManager, Sts, MeteringMarketplace) | `true` | Per‑service endpoint toggles. Leave on unless an endpoint already exists. |

---

## Compute Tiers (EC2)

| Parameter | Default | Notes |
|-----------|---------|-------|
| `ApiInstanceType` | `m7i.4xlarge` | API tier. |
| `ApiDesiredCapacity` | `1` | API instance count. |
| `ModelCpuInstanceType` | `c7i.48xlarge` | CPU model tier. |
| `ModelCpuDesiredCapacity` | `1` | |
| `ModelGpuInstanceType` | `p5en.48xlarge` | GPU inference tier. `p5en.48xlarge` is the production instance type; contact Fundamental if capacity is unavailable in your region. |
| `ModelGpuDesiredCapacity` | `1` | |
| `ModelOrchestrationInstanceType` | `m7i.8xlarge` | Temporal workflow worker (confidential compute). Allowed: `m7i.4xlarge`, `m7i.8xlarge`, `m7i.12xlarge`, `m5.8xlarge`. |
| `ModelOrchestrationDesiredCapacity` | `1` | Set `0` to disable the Temporal worker tier entirely. |
| `PreferredAvailabilityZone` | *(empty)* | AZ for GPU Capacity Block (e.g. `us-west-1a`). |
| `CapacityReservationId` | *(empty)* | GPU Capacity Block reservation (e.g. `cr-1234567890abcdef0`). |
| `ApiS3Path` / `ModelCpuS3Path` / `ModelGpuS3Path` / `ModelOrchestrationS3Path` | version‑pinned | Override the artifact version per tier. Leave at the pinned default. Only set when Fundamental gives you a specific version string. |

### Optional: Split Train/Predict Tiers

For advanced deployments only. Leave all of these at `false` for a standard deployment.

| Parameter | Default | Notes |
|-----------|---------|-------|
| `EnableModelCpuTrain` / `EnableModelCpuPredict` | `false` | Dedicated CPU fleet for training or inference. When enabled, replaces the legacy ModelCPU tier for that workload type. |
| `ModelCpuTrainInstanceType` / `ModelCpuPredictInstanceType` | `c7i.48xlarge` | |
| `ModelCpuTrainDesiredCapacity` / `ModelCpuPredictDesiredCapacity` | `1` | |
| `EnableModelGpuTrain` / `EnableModelGpuPredict` | `false` | Dedicated GPU fleet for training or inference. |
| `ModelGpuTrainInstanceType` / `ModelGpuPredictInstanceType` | `p5en.48xlarge` | |
| `ModelGpuTrainDesiredCapacity` / `ModelGpuPredictDesiredCapacity` | `1` | |

---

## EKS

| Parameter | Default | Notes |
|-----------|---------|-------|
| `EksNodeInstanceType` | `m7i.4xlarge` | Worker node type (general‑purpose node groups, one per AZ). |
| `EksNodeDesiredCapacity` | `1` | Nodes per AZ group. |
| `EksNodeMinCapacity` / `EksNodeMaxCapacity` | `1` / `1` | Auto Scaling bounds. |
| `EksNodeRootVolumeSize` | `100` | Root EBS GiB per node. |
| `EnableEksHeavyNodeGroup` | `false` | Runs one additional dedicated (tainted) EKS node for heavier workloads, on top of the worker nodes. Disabled by default; set `true` only if Fundamental tells you a workload needs the extra reserved capacity. |
| `EksHeavyNodeInstanceType` | `m7i.4xlarge` | Instance type for the additional node. Allowed: `m7i.4xlarge`, `m7i.8xlarge`, `r7i.2xlarge`, `r7i.4xlarge`. |
| `EksHeavyNodeDesiredCapacity` / `EksHeavyNodeMinCapacity` / `EksHeavyNodeMaxCapacity` | `1` / `1` / `1` | Auto Scaling bounds for the additional node. |
| `PrivateEksClusterEndpoint` | `true` | Private‑only API endpoint. |
| `EksServiceIpv4Cidr` | `172.21.0.0/16` | Kubernetes service CIDR. |
| `EksNodeAmiId` | *(empty)* | Optional override; empty uses the EKS‑optimized AMI. |

---

## Images and Version

`FunInfraBundleVersion` and `FunAppBundleVersion` select the released infra and app bundles. The Console Launch page pre-fills them for the version you pick; for CLI deploys, use the version strings Fundamental gives you.

| Parameter | Default | Notes |
|-----------|---------|-------|
| `FunInfraBundleVersion` | version‑pinned | Selects the **infra** bundle (CRDs, infrastructure, the helm‑deployer image, and all third‑party images). The stack derives its bundle/crane/manifest S3 keys from it (`<v>/fundamental-infra-<v>.tar.gz`, `<v>/crane-linux-arm64`, `<v>/manifest.json`) and reads the crd/infra chart versions + helm‑deployer image details from that manifest. Change it on an infra upgrade (see the [Upgrade Guide](./update-guide.md)). |
| `FunAppBundleVersion` | version‑pinned | Selects the **app** bundle (fundamental-application + app images). The stack derives its bundle/manifest S3 keys from it (`<v>/fundamental-app-<v>.tar.gz`, `<v>/manifest.json`) and reads the application chart version from that manifest. Change it on an app upgrade. |
| `BundleS3Bucket` | *(shared bundle bucket)* | S3 bucket holding the offline bundle, crane binary, and `manifest.json`. Defaults to the shared bundle bucket Fundamental grants your account read access to; override only if Fundamental tells you to. |
| `ImageRegistryUri` | *(empty)* | Empty means the importer loads images into **your own** ECR (`<account>.dkr.ecr.<region>.amazonaws.com/fundamental`) and the platform pulls from there. |
| `SkipImageImport` | `false` | Leave `false` for automatic import. Set `true` only if you loaded the bundle into your ECR yourself first; see the Image Bundle Guide. |

> Chart versions and the helm-deployer image are not separate parameters. They live in each bundle's `manifest.json`, so a given pair of bundle versions pins a self-consistent set. The Kubernetes control-plane version is fixed internally (currently **1.36**) and is not customer-settable.

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

Fill the six required values: `FunInfraBundleVersion`, `FunAppBundleVersion`, `AmiId`, `CloudFormationExecutionRoleArn`, `ConsumerVpc1Id`, and `ConsumerVpc1SubnetIds`. Everything else uses the template default. `DeploymentName` defaults to `fundamental`; `EksAdminRoleArn` is optional.

Do not change `ModelGpuInstanceType` as a capacity workaround without checking with Fundamental.

```json
[
  { "ParameterKey": "FunInfraBundleVersion",          "ParameterValue": "REPLACE_WITH_INFRA_VERSION" },
  { "ParameterKey": "FunAppBundleVersion",            "ParameterValue": "REPLACE_WITH_APP_VERSION" },
  { "ParameterKey": "DeploymentName",                 "ParameterValue": "fundamental" },
  { "ParameterKey": "AmiId",                          "ParameterValue": "ami-REPLACE_ME" },
  { "ParameterKey": "CloudFormationExecutionRoleArn", "ParameterValue": "arn:aws:iam::<ACCOUNT_ID>:role/FundamentalPlatform-CFServiceRole" },
  { "ParameterKey": "ConsumerVpc1Id",                 "ParameterValue": "vpc-REPLACE_ME" },
  { "ParameterKey": "ConsumerVpc1SubnetIds",          "ParameterValue": "subnet-REPLACE_ME,subnet-REPLACE_ME_2" },
  { "ParameterKey": "EksAdminRoleArn",                "ParameterValue": "arn:aws:iam::<ACCOUNT_ID>:role/<your-kubectl-role>" }
]
```

> `FunInfraBundleVersion` and `FunAppBundleVersion` are required with no default. Set both on every deploy using the version strings Fundamental provides. On an upgrade, bump whichever bundle changed. To customize EKS or enable split tiers, add the relevant rows from the tables above.

### Deploy command

Get the **template URL** from the Marketplace **Launch CloudFormation** page, then:

```bash
aws cloudformation create-stack \
  --stack-name fundamental \
  --region "$DEPLOYMENT_REGION" \
  --template-url "<MARKETPLACE_TEMPLATE_URL>" \
  --parameters file://params.json \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --role-arn arn:aws:iam::<ACCOUNT_ID>:role/FundamentalPlatform-CFServiceRole
```

Pass the `FundamentalPlatform-CFServiceRole` ARN as `--role-arn` and set `CloudFormationExecutionRoleArn` in `params.json` to the same ARN.

Track progress with:

```bash
aws cloudformation describe-stack-events --stack-name fundamental --region "$DEPLOYMENT_REGION" \
  --query 'StackEvents[?contains(ResourceStatus, `FAILED`)].[LogicalResourceId,ResourceStatusReason]' --output table
```

The deployment takes roughly **45 minutes** because EKS, image import, and Helm install run sequentially. See the [Deployment Guide](./deployment-guide.md) for verification and application setup.
