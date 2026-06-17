# Onboarding a New Customer Account

**Audience:** Fundamental internal / operators.

This note describes how to onboard a new customer account to the Fundamental Platform marketplace deployment.

## Overview

There are two models depending on whether the customer can pull from Fundamental's ECR:

| Customer type | Action needed |
|---------------|---------------|
| **Can pull from our ECR** | Add their AWS account ID to the marketplace allow-list in Terraform |
| **Cannot pull from our ECR** | Send them the offline bundle (no Terraform change needed) |

---

## Model 1: Cross-account ECR pull

### Step 1: Get the customer's AWS account ID

The customer provides their AWS account ID (12-digit number). Do not guess or derive it from other sources.

### Step 2: Add the account to the allow-list in fun-infra-terraform

The ECR resource policy that grants cross-account pull access is managed in `fun-infra-terraform`. Locate the marketplace customer account list (it is in the research ECR configuration, scoped to `marketplace/*` repositories only) and add the new account ID.

The permission granted is limited to pulling from the `marketplace/` namespace only. Customers cannot list or pull from any other path in the registry.

Raise a PR, get it reviewed, and apply via the normal CI pipeline.

### Step 3: Confirm the customer can pull

Ask the customer to run a test pull:

```bash
aws ecr get-login-password --region <REGION> \
  | docker login --username AWS --password-stdin \
    954976309480.dkr.ecr.<REGION>.amazonaws.com

docker pull 954976309480.dkr.ecr.<REGION>.amazonaws.com/marketplace/helm-deployer:<VERSION>
```

If this succeeds, the account is correctly allow-listed. The customer can then proceed with the [Deployment Guide](../deployment-guide.md) without setting `ImageRegistryUri`.

---

## Model 2: Offline bundle

If the customer cannot or will not pull from Fundamental's registry, no Terraform change is needed.

### Step 1: Generate or locate the bundle for the target version

The offline bundle for v1.2.0 is a tarball produced with `imgpkg push --as-tar`. Confirm with the team that the bundle for the required version exists in the designated S3 location.

### Step 2: Share the bundle download link

Provide the customer with:

- A pre-signed S3 URL for the bundle tarball (valid for a reasonable period, typically 7 days), or
- An `s3://` path if the customer has direct S3 access to the shared bucket.

Do not share the raw S3 path publicly. Use pre-signed URLs for external delivery.

### Step 3: Direct the customer to the bundle guide

The customer follows the [Image Bundle Guide](../image-bundle-guide.md) to load the images into their own ECR and then proceeds with the [Deployment Guide](../deployment-guide.md) setting `ImageRegistryUri` to their ECR prefix.

---

## Notes

- Keep a record of which accounts are on the ECR allow-list. The source of truth is the Terraform config, but a short internal log (a comment in the Terraform file or a private doc) helps audit over time.
- If a customer cancels their subscription, remove their account ID from the allow-list in the next convenient Terraform cycle.
- The cross-account pull scope is limited to `marketplace/*`. Customers cannot access any other Fundamental ECR repositories.
