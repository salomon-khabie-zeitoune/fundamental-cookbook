# Upgrade Guide

## Upgrading a Fundamental Platform Deployment (v1.2.0+)

This guide covers how to upgrade a Fundamental Platform deployment that was deployed via AWS Marketplace and CloudFormation.

Upgrades are applied **in place** as a CloudFormation **stack update** on your running stack, with no EC2 or EKS-node replacement in the common case.

---

## In-place update

Two cases are covered, both applied as a CloudFormation **stack update** on your running stack:

- **Application / bundle version bump (no template change).** A new platform version ships as new image bundles, selected by two CloudFormation parameters, `FunInfraBundleVersion` and `FunAppBundleVersion`. You update whichever changed against your existing template; no EC2 instance or EKS-node replacement.
- **Application + infrastructure change (new template).** When a release also changes AWS infrastructure, Fundamental provides a new CloudFormation template. You apply it with **Replace existing template**; in the common case this is still an in-place stack update, and CloudFormation changes only the resources that differ.

| Parameter | Controls |
|-----------|----------|
| `FunInfraBundleVersion` | The infra release to move to. Re-imports the infra bundle and rolls the crd/infra chart + image versions it pins. |
| `FunAppBundleVersion` | The app release to move to. Re-imports the app bundle and rolls the application chart + image versions it pins. |

**How it works:** when you change either version, the image-importer step re-runs and loads that bundle into your ECR (the stack derives the bundle and crane S3 keys from the versions, under `s3://<bundle-bucket>/<version>/`); then the helm-deployer re-runs `helm upgrade --install` using the chart versions and helm-deployer image read from the bundles' `manifest.json`. No EC2 instances or EKS nodes are replaced.

> **Simpler than before:** chart versions and the helm-deployer image are not separate parameters - they travel inside each bundle's `manifest.json`. You change **only** the bundle version(s), and a given pair always pins a self-consistent set. Fundamental hands you the new version strings for each release.

### Steps

1. *(Pre-scan / `SkipImageImport=true` customers only)* load the new bundle into your ECR first, per the [Image Bundle Guide](./image-bundle-guide.md).

2. **AWS CloudFormation Console** - your Fundamental Platform stack - **Update**. Choose **Use existing template** for an application-only update, or **Replace existing template** and paste the new template URL when Fundamental provides one. Click **Next**.

3. Set `FunInfraBundleVersion` and/or `FunAppBundleVersion` to the new version string(s) Fundamental provided (bump only the bundle that changed). For a template update, also set any new infrastructure parameters and the new `AmiId` if provided. *(Pre-scan customers: also leave `SkipImageImport=true`.)*

4. Click **Next** through the screens - review the change set - **Submit**.

5. Monitor the **Events** tab until `UPDATE_COMPLETE`. The importer log `/aws/lambda/<DeploymentName>-image-importer` shows the new load; then the charts roll.

> **Note:** In the application-only case this does not touch the EC2 compute tiers or the EKS control plane - only the bundle import and the Kubernetes workloads.

---

## Upgrading from pre-v1.2.0 (service-role deployments)

If you deployed using the CloudFormation service role on a version prior to v1.2.0, the role needs additional permissions for the EKS tier added in v1.2.0. Before upgrading:

1. Re-run `cloudformation-deploy-role/create-role.sh` from the cookbook, or re-apply the policy files in `cloudformation-deploy-role/policies/`.
2. Then update the stack in place as described above.

Skipping the role refresh causes the upgrade to fail with `AccessDenied` on EKS resources.
