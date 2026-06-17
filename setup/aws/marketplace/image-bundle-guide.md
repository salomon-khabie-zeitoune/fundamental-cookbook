# Image Bundle Guide

This guide is for deployments where your environment **cannot pull images directly from Fundamental's registry**. In this model, Fundamental provides an offline bundle artifact containing all container images and Helm charts. You load the bundle into your own Amazon ECR, then point the CloudFormation stack at your registry.

> **When to use this guide:** If Fundamental has told you to use the offline bundle, or if your network policy prevents cross-account ECR pulls, follow this guide before deploying or upgrading. If you are using the default cross-account pull model, skip this guide.

## Prerequisites

- AWS CLI installed and configured for your account
- Docker CLI installed (used internally by `imgpkg`)
- Sufficient IAM permissions to create ECR repositories and push images
- The offline bundle S3 link provided by Fundamental (format: an S3 pre-signed URL or `s3://` path)

## Step 1: Install imgpkg

`imgpkg` is a Carvel tool for bundling and relocating OCI images. Download the latest release for your platform from [https://github.com/vmware-tanzu/carvel-imgpkg/releases](https://github.com/vmware-tanzu/carvel-imgpkg/releases).

**macOS (Apple Silicon or Intel):**

```bash
# Apple Silicon
curl -LO https://github.com/vmware-tanzu/carvel-imgpkg/releases/latest/download/imgpkg-darwin-arm64
chmod +x imgpkg-darwin-arm64
sudo mv imgpkg-darwin-arm64 /usr/local/bin/imgpkg

# Intel
curl -LO https://github.com/vmware-tanzu/carvel-imgpkg/releases/latest/download/imgpkg-darwin-amd64
chmod +x imgpkg-darwin-amd64
sudo mv imgpkg-darwin-amd64 /usr/local/bin/imgpkg
```

**Linux (x86-64):**

```bash
curl -LO https://github.com/vmware-tanzu/carvel-imgpkg/releases/latest/download/imgpkg-linux-amd64
chmod +x imgpkg-linux-amd64
sudo mv imgpkg-linux-amd64 /usr/local/bin/imgpkg
```

Verify:

```bash
imgpkg version
```

## Step 2: Download the Bundle

Fundamental will provide a pre-signed S3 URL or an `s3://` path for the bundle tarball. Download it to your local machine or a bastion with Docker access.

**Using a pre-signed HTTPS URL (recommended for one-time download):**

```bash
curl -L -o fundamental-bundle-1.2.0.tar "<PRE_SIGNED_URL>"
```

**Using the AWS CLI with an `s3://` path:**

```bash
aws s3 cp s3://<BUNDLE_BUCKET>/<BUNDLE_KEY>/fundamental-bundle-1.2.0.tar .
```

> Replace `<PRE_SIGNED_URL>`, `<BUNDLE_BUCKET>`, and `<BUNDLE_KEY>` with the values provided by Fundamental.

## Step 3: Create Your ECR Repository and Log In

Choose a prefix for your Fundamental images. All bundle images will be pushed under this prefix.

```bash
export CUSTOMER_ACCOUNT_ID=<CUSTOMER_ACCOUNT_ID>
export REGION=<REGION>
export ECR_PREFIX=fundamental  # or any prefix you prefer

# Authenticate Docker to ECR
aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin \
    ${CUSTOMER_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com
```

> Replace `<CUSTOMER_ACCOUNT_ID>` with your AWS account ID and `<REGION>` with your deployment region (for example, `us-west-1`).

ECR repositories are created automatically when you push an image if your IAM policy includes `ecr:CreateRepository`, or you can create them in advance:

```bash
# Optional: pre-create repositories (imgpkg will create them on push if permissions allow)
aws ecr create-repository \
  --repository-name ${ECR_PREFIX}/helm-deployer \
  --region $REGION
```

## Step 4: Push the Bundle to Your ECR

This single command reads the bundle tarball, rewrites all image references to your ECR prefix, and pushes everything:

```bash
imgpkg copy \
  --from-tar fundamental-bundle-1.2.0.tar \
  --to-repo ${CUSTOMER_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_PREFIX} \
  --concurrency 4
```

`imgpkg` reads the bundle's lock file, rewrites every image digest reference to point at your ECR prefix, and pushes all layers. This may take several minutes depending on your upload bandwidth.

> **Note:** The bundle contains approximately 13 container images plus 3 Helm charts as OCI artifacts. Total uncompressed size is approximately 20-30 GiB.

## Step 5: Verify the Images Were Pushed

List repositories to confirm all images are present:

```bash
aws ecr describe-repositories \
  --region $REGION \
  --query 'repositories[?starts_with(repositoryName, `'"${ECR_PREFIX}"'`)].repositoryName' \
  --output table
```

Spot-check a specific image:

```bash
aws ecr list-images \
  --repository-name ${ECR_PREFIX}/helm-deployer \
  --region $REGION \
  --output table
```

You should see at least one image tag listed.

## Step 6: Set the ImageRegistryUri Parameter

When deploying or upgrading the CloudFormation stack, set the `ImageRegistryUri` parameter to your ECR prefix (without a trailing slash):

```
<CUSTOMER_ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/<ECR_PREFIX>
```

For example:

```
123456789012.dkr.ecr.us-west-1.amazonaws.com/fundamental
```

Every image and Helm chart reference in the deployment is derived from this prefix, so the entire deployment pulls from your registry.

> **On upgrade:** When upgrading to a new Fundamental version, repeat Steps 2-5 with the new bundle tarball before updating the CloudFormation stack. See the [Upgrade Guide](./update-guide.md) for the full upgrade workflow.
