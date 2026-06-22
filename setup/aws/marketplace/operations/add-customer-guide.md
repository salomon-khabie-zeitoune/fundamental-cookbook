# Onboarding a New Customer Account

**Audience:** Fundamental internal / operators.

This note describes how to onboard a new customer account to the Fundamental Platform marketplace deployment.

## Overview

Customers never pull from Fundamental's ECR. Each deployment loads its images into the **customer's own ECR** at deploy time (the image-importer Lambda) from an offline bundle we publish to S3. Onboarding a customer is therefore a single Terraform change that grants their account:

- **AMI launch permission** for the platform's hardened AMIs, and
- **cross-account read** on the producer S3 buckets (CloudFormation templates, encrypted model artifacts, and the **image bundle**) so their importer Lambda can fetch the bundle.

Both come from one source of truth.

---

## Step 1: Get the customer's AWS account ID

The customer provides their 12-digit AWS account ID. Do not guess or derive it.

## Step 2: Add the account to `customers.hcl` in fun-infra-terraform

The single source of truth is `live/research/customers.hcl`:

```hcl
locals {
  marketplace_customer_account_ids = [
    "889081505507", # aws team demo - do not remove
    "297464765986", # ADP - do not remove
    "<NEW_ACCOUNT_ID>", # <customer label>
  ]
}
```

This list feeds the `ec2-marketplace` module's `customer_accounts`, which grants the new account both the AMI launch permission and read access on the marketplace S3 buckets (including `fundamental-ec2-marketplace-bundles`). It does **not** grant any ECR access - none is needed.

Raise a PR, get it reviewed, and apply via the normal CI pipeline. One `terraform apply` propagates the new account to the AMI permissions (primary + replica regions) and every marketplace bucket policy.

## Step 3: Confirm the grant

After apply, confirm the account is in the AMI launch permissions and the bundle-bucket policy. The customer then proceeds with the [Deployment Guide](../deployment-guide.md) using the defaults - the importer pulls the bundle and loads their ECR automatically. No `ImageRegistryUri` change is required.

---

## Optional: pre-scan / manual-load customers

If a customer's security process requires scanning the images before they reach their cluster, they still need the Step 2 grant (so they can read the bundle from S3). Additionally:

1. Optionally provide a pre-signed S3 URL for the bundle tarball (instead of relying on their account's bucket read).
2. Direct them to the [Image Bundle Guide](../image-bundle-guide.md): they load the bundle into their own ECR, scan it, then deploy with `SkipImageImport=true` and `ImageRegistryUri` set to their ECR prefix.

No additional Terraform change beyond Step 2.

---

## Notes

- The source of truth for who is onboarded is `live/research/customers.hcl`. Keep the inline `# label` comments accurate - they record who each account is.
- If a customer cancels, remove their account ID from `customers.hcl` in the next convenient Terraform cycle; the next apply revokes the AMI permission and bucket read.
- Customers are granted no ECR access at all; every image lives in their own account after the importer runs.
