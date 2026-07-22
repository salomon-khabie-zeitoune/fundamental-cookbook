# Cluster Debug Access

The Fundamental Platform runs its Kubernetes (EKS) cluster on a **private API endpoint** inside a VPC with **no internet egress (no NAT)**. That means you cannot reach the cluster with `kubectl` directly from your laptop, and the cluster itself cannot reach out.

These two scripts give you temporary `kubectl` access using **only AWS-native services** - no SSH, no VPN, no bastion you have to manage, and no reverse proxy:

| Script | What it does |
|--------|--------------|
| `start-debug-access.sh` | Launches a tiny relay EC2 instance in the platform VPC, opens an AWS Systems Manager (SSM) port-forward from your laptop to the private EKS API, and configures a kubeconfig context. |
| `stop-debug-access.sh`  | Deletes the relay instance and every resource the start script created. |

## How it works

- `kubectl` runs **on your laptop** and talks to `localhost:8443`.
- SSM forwards that to the relay instance over the AWS Systems Manager data channel (reaching the instance through the VPC's existing SSM interface endpoints - no internet needed).
- The relay instance forwards the bytes to the cluster's private API endpoint on port 443. It is a pure TCP relay: nothing is installed on it, and it holds no cluster credentials.
- Your IAM identity authenticates to the cluster normally (`aws eks get-token`), so all access still goes through EKS access entries and is fully audited.

The relay is a stock Amazon Linux 2023 instance (the SSM agent is preinstalled), **not** the platform AMI.

## Prerequisites

- **AWS CLI v2** configured for the account and region where the platform is deployed (e.g. via `AWS_PROFILE`).
- The **Session Manager plugin** for the AWS CLI: <https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html>
- **`kubectl`** installed locally.
- Your IAM role must have a cluster **access entry** (an admin/SSO role granted at deploy time via the `EksAdminRoleArn` parameter, or any role you have added an access entry for). The relay does not grant cluster access - your own identity does.
- Permissions to create an EC2 instance, a security group, and an IAM role/instance profile in the account.

## Usage

From this directory:

```bash
# Start: spins up the relay, configures kubectl, and opens the tunnel (blocks).
AWS_PROFILE=<your-profile> ./start-debug-access.sh <cluster-name> <region>
```

Leave that terminal open. In a **second terminal**, use the cluster:

```bash
kubectl get nodes
kubectl get pods -A
```

When you are done, press **Ctrl-C** in the first terminal to close the tunnel, then tear everything down:

```bash
AWS_PROFILE=<your-profile> ./stop-debug-access.sh <cluster-name> <region>
```

The cluster name is the EKS cluster created by your deployment (it starts with your `DeploymentName`). If you are unsure:

```bash
aws eks list-clusters --region <region>
```

### Options (environment variables)

| Variable | Default | Purpose |
|----------|---------|---------|
| `LOCAL_PORT` | `8443` | Local port the tunnel listens on. Change if 8443 is in use. |
| `INSTANCE_TYPE` | `t4g.small` | Relay instance type. The script auto-selects the matching Amazon Linux 2023 AMI architecture. |

Region may be passed as the second argument or via `AWS_REGION` / `AWS_DEFAULT_REGION`.

## Notes and troubleshooting

- **Re-running `start` is safe.** It reuses the existing relay for the same cluster instead of creating a duplicate.
- **The kubeconfig context only works while the tunnel is open.** It points `kubectl` at `localhost`, so commands will hang or fail to connect once you Ctrl-C the tunnel. Start it again to resume.
- **`Unable to connect to the server` / `connection refused`:** the tunnel is not open, or `LOCAL_PORT` does not match the port `kubectl` is using. Make sure the `start` terminal is still running.
- **`error: You must be logged in to the server (Unauthorized)`:** your IAM identity has no cluster access entry. Ask whoever deployed the platform to add an access entry for your role (or set `EksAdminRoleArn`).
- **Cost:** the relay is a small instance that exists only between `start` and `stop`. Always run `stop` when finished.
- **`start` left a relay running but you closed the terminal:** just run `stop-debug-access.sh` to clean it up, or re-run `start` to reopen the tunnel to the same instance.
