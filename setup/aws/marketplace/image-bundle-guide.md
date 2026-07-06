# Image Bundle Guide (optional pre-scan / manual load)

> **You usually do NOT need this guide.** By default the platform loads all images into your own ECR **automatically** at deploy time (the image-importer Lambda). Follow this guide only if you want to **scan every image yourself before it reaches your cluster**, or your security process otherwise requires loading the images manually. After loading them yourself, you deploy with `SkipImageImport=true` so the stack skips the automatic importer.

These are the same bundles the importer Lambda uses; the only difference is that *you* run the loader instead of the stack. A release ships two bundles (infra + app); load **both**.

## Prerequisites

- AWS CLI installed and configured for your account
- `crane` installed (see Step 1)
- IAM permissions to create ECR repositories and push images (`ecr:CreateRepository`, `ecr:GetAuthorizationToken`, and the layer/put-image actions)
- The offline bundle S3 links provided by Fundamental. A release ships **two** bundles - an **infra** bundle and an **app** bundle - each as its own tarball (a pre-signed URL or an `s3://` path per bundle)

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

**Windows (PowerShell):**

```powershell
$VERSION = "v0.20.2"
Invoke-WebRequest -Uri "https://github.com/google/go-containerregistry/releases/download/$VERSION/go-containerregistry_Windows_x86_64.tar.gz" -OutFile crane.tar.gz
tar -xzf crane.tar.gz crane.exe
```

`tar` ships with Windows 10/11. Move `crane.exe` onto your `PATH` (or run it from the current directory). If you prefer a package manager, `scoop install crane` or `choco install crane` also work.

Verify:

```bash
crane version
```

## Step 2: Download and extract the bundles

A release ships **two** bundles, each under its own version prefix: the **infra** bundle (`fundamental-infra-<infra-version>.tar.gz`) and the **app** bundle (`fundamental-app-<app-version>.tar.gz`). For this release the versions are **infra `2.0.0`** and **app `1.7.0`**. Fundamental provides a pre-signed URL or an `s3://` path for each. Extract each into its own directory so they do not collide (both unpack to a `bundle/` folder).

```bash
# Infra bundle (FunInfraBundleVersion):
aws s3 cp s3://fundamental-ec2-marketplace-bundles/2.0.0/fundamental-infra-2.0.0.tar.gz .
mkdir -p infra && tar -xzf fundamental-infra-2.0.0.tar.gz -C infra

# App bundle (FunAppBundleVersion):
aws s3 cp s3://fundamental-ec2-marketplace-bundles/1.7.0/fundamental-app-1.7.0.tar.gz .
mkdir -p app && tar -xzf fundamental-app-1.7.0.tar.gz -C app
```

> Replace the versions with the values Fundamental provides for your release (and swap the `aws s3 cp` for `curl -L -o <file> "<PRE_SIGNED_URL>"` if you were given pre-signed URLs).

Each archive extracts to a `bundle/` directory (here `infra/bundle/` and `app/bundle/`) containing `INDEX.txt`, an `images/` directory (one OCI layout per image), and `restore-bundle.sh`.

## Step 3: (Optional) Scan the images

This is the reason to use this path. Each image is a standard OCI layout under `<bundle>/images/<name>/`, so you can point your scanner at them locally before anything is pushed. Scan both bundles. For example, with Trivy:

```bash
for d in infra/bundle/images/*/ app/bundle/images/*/; do
  trivy image --input "$d" || true
done
```

Use whichever scanner your organization standardizes on (Trivy, Grype, Amazon Inspector after push, etc.). Proceed only once the images meet your policy.

## Step 4: Load the images into your ECR

Each bundle ships `restore-bundle.sh`, which logs `crane` in to your ECR, creates each repository, and pushes every image preserving its path and tag. Run it for **both** bundles into the **same** registry. Pass the **full registry URI including the `/fundamental` prefix** - this is exactly the value you will give CloudFormation as `ImageRegistryUri`.

```bash
export ACCOUNT_ID=<ACCOUNT_ID>
export REGION=<REGION>          # e.g. us-west-1
export REGISTRY_URI=${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/fundamental

# Infra bundle:
( cd infra/bundle && ./restore-bundle.sh --registry-uri ${REGISTRY_URI} --region ${REGION} )

# App bundle:
( cd app/bundle && ./restore-bundle.sh --registry-uri ${REGISTRY_URI} --region ${REGION} )
```

Each image is pushed to `<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/fundamental/<path>:<tag>`. When it finishes, the script prints the exact `ImageRegistryUri` and `SkipImageImport` values to set.

> Together the two bundles contain the full platform image and chart set; ~4.5 GiB compressed.

## Step 5: Verify the images were pushed

```bash
aws ecr describe-repositories \
  --region $REGION \
  --query 'repositories[?starts_with(repositoryName, `fundamental/`)].repositoryName' \
  --output table

aws ecr list-images \
  --repository-name fundamental/dockerhub/temporalio/server \
  --region $REGION \
  --output table
```

You should see the full set of `fundamental/*` repositories, each with at least one tag.

## Step 6: Deploy with the importer skipped

When you launch (or upgrade) the CloudFormation stack, set:

| Parameter | Value |
|-----------|-------|
| `SkipImageImport` | `true` |
| `ImageRegistryUri` | `<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/fundamental` |

For example, `ImageRegistryUri = 123456789012.dkr.ecr.us-west-1.amazonaws.com/fundamental`.

Every image reference in the template is built as `${ImageRegistryUri}/<path>:<tag>`, so `${ImageRegistryUri}/dockerhub/temporalio/server:1.31.0` resolves to exactly where `restore-bundle.sh` placed it. With `SkipImageImport=true`, the stack does not run the importer Lambda and goes straight to deploying from your pre-loaded registry.

> **On upgrade:** repeat Steps 2-5 with the new bundle(s) Fundamental provides (bump only the bundle that changed - infra and app version independently), then update the stack. See the [Upgrade Guide](./update-guide.md).
