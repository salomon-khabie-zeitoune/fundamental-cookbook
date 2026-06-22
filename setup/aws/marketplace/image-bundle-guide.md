# Image Bundle Guide (optional pre-scan / manual load)

> **You usually do NOT need this guide.** By default the platform loads all images into your own ECR **automatically** at deploy time (the image-importer Lambda). Follow this guide only if you want to **scan every image yourself before it reaches your cluster**, or your security process otherwise requires loading the images manually. After loading them yourself, you deploy with `SkipImageImport=true` so the stack skips the automatic importer.

This is the same bundle the importer Lambda uses; the only difference is that *you* run the loader instead of the stack.

## Prerequisites

- AWS CLI installed and configured for your account
- `crane` installed (see Step 1)
- IAM permissions to create ECR repositories and push images (`ecr:CreateRepository`, `ecr:GetAuthorizationToken`, and the layer/put-image actions)
- The offline bundle S3 link provided by Fundamental (a pre-signed URL or an `s3://` path)

## Step 1: Install crane

`crane` copies OCI images and artifacts between registries and local layouts without a Docker daemon. It is the same tool the loader script uses.

**macOS:**

```bash
brew install crane
```

**Linux:**

```bash
VERSION=v0.20.2
curl -fsSL -o crane.tar.gz \
  "https://github.com/google/go-containerregistry/releases/download/${VERSION}/go-containerregistry_Linux_x86_64.tar.gz"
sudo tar -xzf crane.tar.gz -C /usr/local/bin crane
```

Verify:

```bash
crane version
```

## Step 2: Download and extract the bundle

Fundamental provides a pre-signed URL or an `s3://` path for the bundle tarball.

```bash
# Pre-signed HTTPS URL:
curl -L -o fundamental-marketplace-1.2.0.tar.gz "<PRE_SIGNED_URL>"

# or, with an s3:// path:
aws s3 cp s3://fundamental-ec2-marketplace-bundles/1.2.0/fundamental-marketplace-1.2.0.tar.gz .

tar -xzf fundamental-marketplace-1.2.0.tar.gz
```

> Replace `<PRE_SIGNED_URL>` / the version with the values Fundamental provides.

The archive extracts to `bundle/` containing `INDEX.txt`, an `images/` directory (one OCI layout per image), and `restore-bundle.sh`.

## Step 3: (Optional) Scan the images

This is the reason to use this path. Each image is a standard OCI layout under `bundle/images/<name>/`, so you can point your scanner at them locally before anything is pushed. For example, with Trivy:

```bash
for d in bundle/images/*/; do
  trivy image --input "$d" || true
done
```

Use whichever scanner your organization standardizes on (Trivy, Grype, Amazon Inspector after push, etc.). Proceed only once the images meet your policy.

## Step 4: Load the images into your ECR

The bundle ships `restore-bundle.sh`, which logs `crane` in to your ECR, creates each repository, and pushes every image preserving its path and tag. Pass the **full registry URI including the `/marketplace` prefix** - this is exactly the value you will give CloudFormation as `ImageRegistryUri`.

```bash
export ACCOUNT_ID=<ACCOUNT_ID>
export REGION=<REGION>          # e.g. us-west-1

cd bundle
./restore-bundle.sh \
  --registry-uri ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/marketplace \
  --region ${REGION}
```

Each image is pushed to `<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/marketplace/<path>:<tag>`. When it finishes, the script prints the exact `ImageRegistryUri` and `SkipImageImport` values to set.

> The bundle contains ~16 images/charts; ~2.8 GiB compressed.

## Step 5: Verify the images were pushed

```bash
aws ecr describe-repositories \
  --region $REGION \
  --query 'repositories[?starts_with(repositoryName, `marketplace/`)].repositoryName' \
  --output table

aws ecr list-images \
  --repository-name marketplace/dockerhub/temporalio/server \
  --region $REGION \
  --output table
```

You should see ~16 `marketplace/*` repositories, each with at least one tag.

## Step 6: Deploy with the importer skipped

When you launch (or upgrade) the CloudFormation stack, set:

| Parameter | Value |
|-----------|-------|
| `SkipImageImport` | `true` |
| `ImageRegistryUri` | `<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/marketplace` |

For example, `ImageRegistryUri = 123456789012.dkr.ecr.us-west-1.amazonaws.com/marketplace`.

Every image reference in the template is built as `${ImageRegistryUri}/<path>:<tag>`, so `${ImageRegistryUri}/dockerhub/temporalio/server:1.31.0` resolves to exactly where `restore-bundle.sh` placed it. With `SkipImageImport=true`, the stack does not run the importer Lambda and goes straight to deploying from your pre-loaded registry.

> **On upgrade:** repeat Steps 2-5 with the new bundle Fundamental provides, then update the stack. See the [Upgrade Guide](./update-guide.md).
