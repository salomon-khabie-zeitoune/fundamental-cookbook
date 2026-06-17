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

Supporting a new region requires two things:

1. **ECR replication** - container images and Helm charts stored in the primary ECR (account 954976309480, `us-west-1`) must be replicated to the new region so cross-account pulls work without cross-region traffic.
2. **Lambda image availability** - the helm-deployer Lambda image must be present in every supported region (Lambda requires the image in the same region as the function).

## Steps to add a new region

### 1. Add the region to ECR replication rules

In `fun-infra-terraform`, update the ECR replication configuration to add the new region as a destination. The existing config replicates `us-west-1` -> `us-east-1`; add the new region alongside.

File location (approximate): `live/research/us-west-1/ecr/` or the marketplace ECR module - confirm with the current Terraform state.

Add the new region as an additional replication destination. After applying, ECR will automatically replicate all `marketplace/*` repositories to the new region.

### 2. Push the Lambda image to the new region

The helm-deployer Lambda image must be available in the new region. Either:

- Add the new region to the cross-region image push step in the marketplace release pipeline, or
- Manually copy the image using `imgpkg copy` or `aws ecr batch-get-image` + `batch-check-layer-availability` + `put-image` if doing a one-off.

### 3. Test the offline bundle path in the new region

If the new region will support offline bundle customers, verify that `imgpkg copy --from-tar ... --to-repo <account>.dkr.ecr.<new-region>.amazonaws.com/<prefix>` works correctly. ECR endpoints in all standard regions use the same format.

### 4. Update documentation

Add the new region to the `Supported Regions` note in `deployment-guide.md`:

```
> **Supported Regions:** `us-west-1`, `us-east-1`, `<new-region>`
```

## Notes

- Replication is eventually consistent. Allow a few minutes after enabling replication before testing pulls from the new region.
- ECR replication copies images by digest. Customers pulling by tag get the correct digest as long as the tag existed in the source before replication ran.
- The marketplace CloudFormation template S3 bucket also needs to exist in the new region if customers will launch from the Marketplace console (Marketplace copies templates per-region automatically, but verify this with the Marketplace team if it is a new region).
