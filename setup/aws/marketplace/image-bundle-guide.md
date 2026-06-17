# Image Bundle Guide

This guide is for deployments where your environment **cannot pull images directly from Fundamental's registry**. In this model, Fundamental provides an offline bundle artifact containing all container images. You load the bundle into your own Amazon ECR, then point the CloudFormation stack at your registry.

> **When to use this guide:** If Fundamental has told you to use the offline bundle, or if your network policy prevents cross-account ECR pulls, follow this guide before deploying or upgrading. If you are using the default cross-account pull model, skip this guide.

## Prerequisites

- AWS CLI installed and configured for your account
- skopeo installed (see Step 1)
- Sufficient IAM permissions to push images to ECR (and `ecr:CreateRepository` if repositories do not exist yet)
- The offline bundle S3 link provided by Fundamental (format: an S3 pre-signed URL or `s3://` path)

## Step 1: Install skopeo

`skopeo` copies OCI images between registries and local directories without requiring a Docker daemon.

**macOS:**

```bash
brew install skopeo
```

**Linux (Debian/Ubuntu):**

```bash
sudo apt-get update && sudo apt-get install -y skopeo
```

**Linux (RHEL/Amazon Linux 2023):**

```bash
sudo dnf install -y skopeo
```

Verify:

```bash
skopeo --version
```

## Step 2: Download the Bundle

Fundamental will provide a pre-signed S3 URL or an `s3://` path for the bundle tarball. Download it to your local machine or a bastion with network access to ECR.

**Using a pre-signed HTTPS URL (recommended for one-time download):**

```bash
curl -L -o fundamental-marketplace-1.2.0.tar.gz "<PRE_SIGNED_URL>"
```

**Using the AWS CLI with an `s3://` path:**

```bash
aws s3 cp s3://<BUNDLE_BUCKET>/<VERSION>/fundamental-marketplace-1.2.0.tar.gz .
```

> Replace `<PRE_SIGNED_URL>`, `<BUNDLE_BUCKET>`, and `<VERSION>` with the values provided by Fundamental.

Extract the archive:

```bash
tar -xzf fundamental-marketplace-1.2.0.tar.gz
```

## Step 3: Log In to ECR

```bash
export ACCOUNT_ID=<ACCOUNT_ID>
export REGION=<REGION>
export ECR_PREFIX=fundamental  # or any prefix you prefer

aws ecr get-login-password --region $REGION \
  | skopeo login --username AWS --password-stdin \
    ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com
```

> Replace `<ACCOUNT_ID>` with your AWS account ID and `<REGION>` with your deployment region (for example, `us-west-1`).

ECR repositories are created automatically on first push if your IAM policy includes `ecr:CreateRepository` -- no need to pre-create them.

## Step 4: Run the Restore Script

The bundle includes a `restore-bundle.sh` script that mirrors every image from the extracted bundle into your ECR, preserving the full image path and tag.

```bash
./bundle/restore-bundle.sh \
  --ecr ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com \
  --prefix ${ECR_PREFIX} \
  --region ${REGION}
```

The script pushes each image to `<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<ECR_PREFIX>/marketplace/<path>:<tag>`. When it finishes, it prints the exact `ImageRegistryUri` value to use in the next step.

> **Note:** skopeo must be installed on the machine running this script. The bundle contains approximately 13 container images; total uncompressed size is approximately 20-30 GiB.

## Step 5: Verify the Images Were Pushed

List repositories to confirm images are present:

```bash
aws ecr describe-repositories \
  --region $REGION \
  --query 'repositories[?starts_with(repositoryName, `'"${ECR_PREFIX}"'`)].repositoryName' \
  --output table
```

Spot-check a specific image:

```bash
aws ecr list-images \
  --repository-name ${ECR_PREFIX}/marketplace/temporalio/server \
  --region $REGION \
  --output table
```

You should see at least one image tag listed.

## Step 6: Set the ImageRegistryUri Parameter

When deploying or upgrading the CloudFormation stack, set the `ImageRegistryUri` parameter to:

```
<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<ECR_PREFIX>/marketplace
```

For example:

```
123456789012.dkr.ecr.us-west-1.amazonaws.com/fundamental/marketplace
```

Every image reference in the CloudFormation template is built as `${ImageRegistryUri}/<path>:<tag>`, so `${ImageRegistryUri}/temporalio/server:1.31.0` resolves to `123456789012.dkr.ecr.us-west-1.amazonaws.com/fundamental/marketplace/temporalio/server:1.31.0` -- exactly where `restore-bundle.sh` placed it.

> **On upgrade:** When upgrading to a new Fundamental version, repeat Steps 2-5 with the new bundle tarball before updating the CloudFormation stack. See the [Upgrade Guide](./update-guide.md) for the full upgrade workflow.
