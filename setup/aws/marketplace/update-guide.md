# Upgrade Guide

## Upgrading a Fundamental Platform Deployment (v1.2.0+)

This guide covers all upgrade paths for the Fundamental Platform deployed via AWS Marketplace and CloudFormation.

There are two distinct upgrade paths depending on what changed:

| Path | When to use |
|------|-------------|
| [Path A: Chart-only update](#path-a-chart-only-update) | Updating application versions (Temporal, database operator, platform app) without changing infrastructure or the CloudFormation template |
| [Path B: Full upgrade (delete and recreate)](#path-b-full-upgrade-delete-and-recreate) | Upgrading to a new platform version that includes infrastructure changes, a new AMI, or a new CloudFormation template |

---

## Path A: Chart-only Update

The Helm chart versions are exposed as CloudFormation parameters:

| Parameter | Controls |
|-----------|----------|
| `FunCrdChartVersion` | CRD chart version |
| `FunInfraChartVersion` | Infrastructure chart version (Temporal, database, networking) |
| `FunAppChartVersion` | Application chart version (the Fundamental platform app) |

When you update these parameters via a **CloudFormation stack update**, the helm-deployer Lambda re-runs `helm upgrade --install` for the affected charts. No EC2 instances or EKS nodes are replaced - only the Kubernetes workloads are updated.

### Steps

1. Go to **AWS CloudFormation Console** - find your existing Fundamental Platform stack - click **Update**.

2. Select **Use existing template** - click **Next**.

3. Update one or more of `FunCrdChartVersion`, `FunInfraChartVersion`, `FunAppChartVersion` to the new values provided by Fundamental.

4. Click **Next** through the remaining screens - review the change set - click **Submit**.

5. Monitor the **Events** tab. The update completes when the stack returns to `UPDATE_COMPLETE`.

> **Note:** Chart-only updates do not affect the EC2 compute tiers or the EKS control plane. They are faster than a full upgrade and do not require any bundle pre-step (or, if using the offline bundle model, only a new bundle push if the charts or images changed - Fundamental will tell you whether a new bundle is needed).

---

## Path B: Full Upgrade (Delete and Recreate)

Full upgrades (new CloudFormation template version, new AMI, infrastructure changes) use a **delete-and-recreate** approach. There is no in-place migration path for infrastructure-level upgrades.

> **Important:** This process will recreate all infrastructure. Temporal workflow history, the in-cluster Postgres database, and all ephemeral state will be lost. If you have trained models stored in the deployment's S3 bucket and want to retain them, see [Retaining trained-model data](#retaining-trained-model-data) below before deleting the stack.

### Overview

1. (If using offline bundle) Push the new bundle to your ECR.
2. Delete the old CloudFormation stack.
3. Deploy the new stack with a **different `DeploymentName`**.

Using a different `DeploymentName` avoids S3 bucket name collisions. The model-artifact S3 bucket name is derived from `DeploymentName`, so the old and new stacks use different bucket names and can coexist during migration.

### Step 1: Pre-step for offline bundle deployments

If you are using the offline bundle model (you set `ImageRegistryUri` in your existing deployment), push the new version bundle to your ECR before proceeding:

```bash
# Follow image-bundle-guide.md Steps 1-5 with the new bundle tarball
# provided by Fundamental for this version.
```

See [Image Bundle Guide](./image-bundle-guide.md) for the full procedure.

If you are using the default cross-account pull model, skip this step.

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
- If you are using the offline bundle model, set `ImageRegistryUri` to your ECR prefix as before.
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

If you deployed using the CloudFormation service role (Option B) on a version prior to v1.2.0, the role needs additional permissions for the EKS tier added in v1.2.0. Before upgrading:

1. Re-run `cloudformation-deploy-role/create-role.sh` from the cookbook, or re-apply the policy files in `cloudformation-deploy-role/policies/`.
2. Then proceed with Path B (delete-and-recreate) above.

Skipping the role refresh causes the upgrade to fail with `AccessDenied` on EKS resources.
