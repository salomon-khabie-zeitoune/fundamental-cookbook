# Upgrade Guide

## Upgrading a Fundamental Platform Deployment (v1.2.0+)

This guide covers all upgrade paths for the Fundamental Platform deployed via AWS Marketplace and CloudFormation.

There are two distinct upgrade paths depending on what changed:

| Path | When to use |
|------|-------------|
| [Path A: In-place update](#path-a-in-place-update) | **The standard path for nearly all updates** - new application/bundle versions, and most infrastructure or template changes - applied as a CloudFormation stack update on your running stack. No EC2 or EKS-node replacement in the common case. |
| [Path B: Delete and recreate](#path-b-delete-and-recreate) | **Last-resort fallback**, only when an in-place update isn't feasible (for example, a first-time migration). Deploys a fresh stack under a new `DeploymentName`; trained-model S3 data can be retained. |

---

## Path A: In-place update

This is the **standard, recommended** path for almost all updates, applied as a CloudFormation **stack update** on your running stack. Two cases are covered:

- **Application / bundle version bump (no template change).** A new platform version ships as a new image bundle plus matching chart-version values, all exposed as CloudFormation parameters. You update those parameters against your existing template; no EC2 instance or EKS-node replacement.
- **Application + infrastructure change (new template).** When a release also changes AWS infrastructure, Fundamental provides a new CloudFormation template. You apply it with **Replace existing template**; in the common case this is still an in-place stack update, and CloudFormation changes only the resources that differ.

| Parameter | Controls |
|-----------|----------|
| `BundleS3Key` | The offline image bundle to load (contains the images the new chart versions need) |
| `CraneS3Key` | The crane binary shipped with that bundle |
| `FunCrdChartVersion` | CRD chart version |
| `FunInfraChartVersion` | Infrastructure chart version |
| `FunAppChartVersion` | Application chart version |

**How it works:** when you change `BundleS3Key`, the image-importer step re-runs and loads the new bundle's images into your ECR; then the helm-deployer re-runs `helm upgrade --install` for the new chart versions.

> **Important:** a chart-version bump must be paired with the matching `BundleS3Key`/`CraneS3Key`. Fundamental hands you all of these values together for each release. If you change only the chart versions without the new bundle, the new images will not be in your ECR and the upgrade will fail to pull them.

### Steps

1. *(Pre-scan / `SkipImageImport=true` customers only)* load the new bundle into your ECR first, per the [Image Bundle Guide](./image-bundle-guide.md).

2. **AWS CloudFormation Console** - your Fundamental Platform stack - **Update**. Choose **Use existing template** for an application-only update, or **Replace existing template** and paste the new template URL when Fundamental provides one. Click **Next**.

3. Set the new values Fundamental provided: `BundleS3Key`, `CraneS3Key`, and the relevant `Fun*ChartVersion`(s). For a template update, also set any new infrastructure parameters and the new `AmiId` if provided. *(Pre-scan customers: skip the two bundle keys, set only the chart versions, leave `SkipImageImport=true`.)*

4. Click **Next** through the screens - review the change set - **Submit**.

5. Monitor the **Events** tab until `UPDATE_COMPLETE`. The importer log `/aws/lambda/<DeploymentName>-image-importer` shows the new load; then the charts roll.

> **Note:** In the application-only case this does not touch the EC2 compute tiers or the EKS control plane - only the bundle import and the Kubernetes workloads.

---

## Path B: Delete and recreate

This is the **last-resort fallback**, used only when an in-place update (Path A) isn't feasible - in practice, rarely. One example is a first-time migration where standing up a fresh stack under a new name is simpler than reconciling the existing one. You deploy a new stack under a new `DeploymentName`; trained-model S3 data can be retained (see [Retaining trained-model data](#retaining-trained-model-data)).

> **Important:** This process recreates all infrastructure. Temporal workflow history, the in-cluster Postgres database, and all ephemeral state will be lost. If you have trained models stored in the deployment's S3 bucket and want to retain them, see [Retaining trained-model data](#retaining-trained-model-data) below before deleting the stack.

### Overview

1. Delete the old CloudFormation stack.
2. Deploy the new stack with a **different `DeploymentName`** (it loads its own images automatically).

Using a different `DeploymentName` avoids S3 bucket name collisions. The model-artifact S3 bucket name is derived from `DeploymentName`, so the old and new stacks use different bucket names and can coexist during migration.

### Step 1: Images (automatic)

The new stack loads all its images into your ECR automatically at create time (the image-importer step), using the bundle version pinned in the template you deploy. There is **no manual image pre-step**.

*Pre-scan / `SkipImageImport=true` customers only:* load the new version's bundle into your ECR first per the [Image Bundle Guide](./image-bundle-guide.md), and deploy the new stack with `SkipImageImport=true`.

### Step 2: (Optional) Retain trained-model data

If you want to keep the trained models from your current deployment, note the name of the model-artifact S3 bucket before deleting:

```bash
export OLD_STACK_NAME=<your-current-stack-name>
export DEPLOYMENT_REGION=<your-region>

aws cloudformation describe-stack-resources \
  --stack-name $OLD_STACK_NAME \
  --region $DEPLOYMENT_REGION \
  --query 'StackResources[?ResourceType==`AWS::S3::Bucket`].PhysicalResourceId' \
  --output table
```

To retain the bucket, either:
- Remove the bucket from the stack before deleting (set a deletion policy if your template supports it), or
- Copy the data to a separate bucket before deletion:

```bash
aws s3 sync s3://<OLD_MODEL_BUCKET> s3://<YOUR_BACKUP_BUCKET> --region $DEPLOYMENT_REGION
```

### Step 3: Delete the old stack

> **Warning:** This permanently destroys all stack resources including VPCs, EC2 instances, the EKS cluster, RDS/CNPG databases, and S3 buckets (unless you retained them above).

**Using AWS Console:**

Go to **CloudFormation** - select your existing stack - click **Delete** - confirm deletion.

**Using AWS CLI:**

```bash
aws cloudformation delete-stack \
  --stack-name $OLD_STACK_NAME \
  --region $DEPLOYMENT_REGION
```

Wait for deletion to complete:

```bash
aws cloudformation wait stack-delete-complete \
  --stack-name $OLD_STACK_NAME \
  --region $DEPLOYMENT_REGION
```

### Step 4: Deploy the new stack with a new DeploymentName

Deploy exactly as described in the [Deployment Guide](./deployment-guide.md), with these differences:

- Use a **new `DeploymentName`** (for example, `fundamental-v2` or `fundamental-20261201`). Do **not** reuse the old name.
- Leave `ImageRegistryUri`/`SkipImageImport` at their defaults for the automatic import. (Pre-scan customers: set `SkipImageImport=true` and `ImageRegistryUri` to your ECR prefix after loading the bundle.)
- If Fundamental provided a new CloudFormation template URL for this version, use it.

> **Tip:** The CloudFormation template URL and new AMI ID are available on the AWS Marketplace launch page. Navigate to your subscription, select the new version, and copy the S3 URL and AMI ID as described in Steps 1-2 of the Marketplace launch flow.

### Step 5: Verify the new deployment

Follow the [Deployment Guide - Step 5: Verify Deployment](./deployment-guide.md#5-verify-deployment) for the full verification checklist.

---

## Retaining trained-model data

The model-artifact S3 bucket is named after your `DeploymentName`. On delete-and-recreate:

- If you want to **discard** old model data: do nothing. The bucket is deleted with the stack.
- If you want to **keep** old model data: copy it to a separate bucket before deleting, or re-point your applications to the old bucket name (it will still exist if you retained it).

There is no automatic migration of model artifacts between stack versions.

---

## Upgrading from pre-v1.2.0 (service-role deployments)

If you deployed using the CloudFormation service role on a version prior to v1.2.0, the role needs additional permissions for the EKS tier added in v1.2.0. Before upgrading:

1. Re-run `cloudformation-deploy-role/create-role.sh` from the cookbook, or re-apply the policy files in `cloudformation-deploy-role/policies/`.
2. Then update the stack using Path A (in-place). Use Path B only if an in-place update isn't feasible.

Skipping the role refresh causes the upgrade to fail with `AccessDenied` on EKS resources.
