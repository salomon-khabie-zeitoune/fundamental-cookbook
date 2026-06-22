# Fundamental Platform - AWS Marketplace

Deploy the Fundamental Platform into your AWS environment via AWS Marketplace and CloudFormation.

## Customer guides

| Resource | Description |
|----------|-------------|
| [Deployment Guide](deployment-guide.md) | Step-by-step instructions for deploying and connecting to the platform (v1.2.0) |
| [Upgrade Guide](update-guide.md) | Chart/image updates (new bundle + chart versions) and full delete-and-recreate upgrade paths |
| [Image Bundle Guide](image-bundle-guide.md) | Optional: load the image bundle into your own ECR yourself (to pre-scan images first). By default the platform loads it automatically. |
| [CloudFormation Deploy Role](cloudformation-deploy-role/) | IAM service role for deploying without admin permissions |

## Operator guides

| Resource | Description |
|----------|-------------|
| [Add a Region](operations/add-region-guide.md) | How Fundamental adds support for a new deployment region |
| [Onboard a New Customer](operations/add-customer-guide.md) | How to grant a new customer access or provide the offline bundle |
