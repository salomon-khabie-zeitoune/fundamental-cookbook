# Upgrade Guide

## Upgrading a Fundamental Platform Deployment (v2.0.0+)

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

**How it works:** when you change either version, the stack loads the new bundle into your account's ECR and upgrades the platform to it in place - no EC2 instances or EKS nodes are replaced. You change only the bundle version(s); each release is a self-consistent set, and Fundamental hands you the new version strings.

### Steps

1. *(Pre-scan / `SkipImageImport=true` customers only)* load the new bundle into your ECR first, per the [Image Bundle Guide](./image-bundle-guide.md).

2. **AWS CloudFormation Console** - your Fundamental Platform stack - **Update**. Choose **Use existing template** for an application-only update, or **Replace existing template** and paste the new template URL when Fundamental provides one. Click **Next**.

3. Set `FunInfraBundleVersion` and/or `FunAppBundleVersion` to the new version string(s) Fundamental provided (bump only the bundle that changed). For a template update, also set any new infrastructure parameters and the new `AmiId` if provided. *(Pre-scan customers: also leave `SkipImageImport=true`.)*

4. Click **Next** through the screens - review the change set - **Submit**.

5. Monitor the **Events** tab until `UPDATE_COMPLETE`. The importer log `/aws/lambda/<DeploymentName>-image-importer` shows the new load; then the charts roll.

> **Note:** In the application-only case this does not touch the EC2 compute tiers or the EKS control plane - only the bundle import and the Kubernetes workloads.

---

## Upgrading from pre-v2.0.0 (service-role deployments)

If you deployed using the CloudFormation service role on a version prior to v2.0.0, the role needs additional permissions for the EKS tier added in v2.0.0. Before upgrading:

1. Re-run `cloudformation-deploy-role/create-role.sh` from the cookbook, or re-apply the policy files in `cloudformation-deploy-role/policies/`.
2. Then update the stack in place as described above.

Skipping the role refresh causes the upgrade to fail with `AccessDenied` on EKS resources.
