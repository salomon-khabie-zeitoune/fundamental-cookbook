# Adding a New Deployment Region

**Audience:** Fundamental internal / operators.

This note describes how to extend the platform to support a new AWS deployment region for marketplace customers.

## Current state

Tested and supported regions (as of v1.2.0):

| Region | Status |
|--------|--------|
| `us-west-1` | Primary - fully supported |
| `us-east-1` | Supported |

## What "adding a region" means

Customers load every image into **their own** ECR in their deployment region from the offline bundle (the image-importer Lambda), so there is **no cross-account ECR pull to replicate**. Supporting a new region requires:

1. **Hardened AMI in the region** - the platform AMIs must be shared into the new region. They are replicated by the `ec2-marketplace` Terraform module to its replica regions.
2. **Bundle + templates reachable from the region** - the importer Lambda reads the bundle from S3 and the stack fetches its nested templates from S3. Both buckets must be reachable from the new region.
3. **Templates + bundle published for the version** - the release pipeline must have uploaded them.

(VPC endpoints for ECR and S3 are created by the stack itself in the customer's region; AWS provides those service endpoints in all standard regions.)

## Steps to add a new region

### 1. Replicate the AMI to the new region

In `fun-infra-terraform`, add the region to the `ec2-marketplace` module's `replica_regions` (currently `us-east-1`, `us-west-2`) and apply. The module copies the AMI and re-shares launch permission to the fundamental + customer accounts in the new region.

### 2. Make the bundle + templates reachable

The bundle bucket (`fundamental-ec2-marketplace-bundles`) and the template bucket (`fundamental-ec2-cfn-templates`) live in `us-west-1`. Cross-region S3 reads work as-is, so a single bucket already serves other regions. For lower latency/egress you can optionally add a regional bundle bucket and replicate to it (mirror the regional-bucket pattern in `modules/ec2-marketplace/s3-regional.tf`) and set the `BundleS3Bucket` parameter accordingly.

### 3. Publish templates + bundle for the version

Run the release pipeline (`Release` / `Release Bundle`) so the nested templates are in the template bucket and the bundle plus the `crane` binary are in the bundle bucket under the version key.

### 4. Update documentation

Add the new region to the `Supported Regions` note in `deployment-guide.md`:

```
> **Supported Regions:** `us-west-1`, `us-east-1`, `<new-region>`
```

## Notes

- The helm-deployer image is part of the bundle, so it lands in the customer's own ECR in their region automatically - there is no separate per-region Lambda-image push.
- For a brand-new region, confirm with the Marketplace team that the console copies launch templates per-region as expected.
