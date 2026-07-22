# Model Test Jumpbox

The Fundamental Platform exposes its API through a **private REST API Gateway** with **IAM (SigV4) authentication**. Requests must arrive through a registered consumer VPC endpoint, and every method requires an IAM identity allowed to `execute-api:Invoke`. There is no public URL and no API key.

That means you cannot call the model from your laptop directly, and a plain port-forward is not enough. These scripts test the same path your application uses by running from a small jumpbox inside a consumer VPC:

| Script | What it does |
|--------|--------------|
| `start-model-test.sh` | Launches a tiny jumpbox EC2 instance in a **consumer VPC**, attaches an instance role that can invoke the API, installs the Fundamental SDK, and drops you into a shell - over **SSM** (default) or **SSH** - with `FUNDAMENTAL_API_URL` and `AWS_REGION` already set. |
| `stop-model-test.sh`  | Deletes the jumpbox and every resource the start script created. |

Two connection modes are supported (set with `ACCESS_MODE`):

- **`ssm`** (default) - connect over AWS Systems Manager. No public IP and no SSH key; needs the Session Manager plugin locally and SSM connectivity in the consumer VPC.
- **`ssh`** - connect over SSH with a key pair. The jumpbox gets a public IP in a public subnet, with port 22 locked to your IP. Use this when you do not have SSM.

## How it works

```
your laptop                consumer VPC                       platform VPC
+-----------+   SSM shell   +-------------+   IAM SigV4        +------------------+
|  aws ssm  |-------------->|  jumpbox EC2|----------------+   |  private REST    |
|  start-   |  (Systems Mgr)|  + SDK +    |  execute-api   |   |  API Gateway     |
|  session  |               |  instance  |  VPC endpoint  +-->|  (AWS_IAM auth)  |
+-----------+               |  role       |                    +--------+---------+
                            +-------------+                              | VPC Link
                                                                +--------v---------+
                                                                |  API NLB -> app  |
                                                                +------------------+
```

- The jumpbox runs **inside a consumer VPC** whose `execute-api` interface endpoint is registered with the private API. It never runs in the Fundamental platform VPC.
- The jumpbox's instance role carries the deployment's **API invoke policy** (`execute-api:Invoke`), so the SDK signs requests with SigV4 using the instance role and the private API authorizes them.
- You run the Python test **on the jumpbox** (over SSM or SSH). Calls go to `https://<api-id>.execute-api.<region>.amazonaws.com/prod` through the consumer VPC endpoint - the same path your application uses.

## Prerequisites

- **AWS CLI v2** configured for the account and region where the platform is deployed (e.g. via `AWS_PROFILE`).
- For **SSM mode** (default): the **Session Manager plugin** for the AWS CLI: <https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html>
- For **SSH mode** (`ACCESS_MODE=ssh`): an SSH client. The script creates a key pair, opens port 22 to your current public IP, and launches the jumpbox in a **public subnet** of the consumer VPC.
- **A registered consumer VPC.** At least one consumer VPC must be configured on the deployment through `ConsumerVpc1Id` / `ConsumerVpc1SubnetIds` or one of the additional `ConsumerVpc<N>*` parameter groups. If none is registered, the script stops and tells you how to add one.
- **The jumpbox needs egress** to install the SDK from `dl.cloudsmith.io` (for `fundamental-client[aws-marketplace]`) and `pypi.org` (for `numpy` / `scikit-learn`). In **SSM mode** it also needs SSM connectivity (`ssm` / `ssmmessages` / `ec2messages` interface endpoints, or a NAT path); in **SSH mode** the public subnet's internet gateway covers both.
- The deployment and the consumer VPC must be in the **same AWS account** (the jumpbox uses an instance profile created from the deployment's exports).
- **A Cloudsmith API token** for the `fundamental-client` index, exported as `CLOUDSMITH_API_KEY`. The SDK is not on public PyPI; it installs from `dl.cloudsmith.io`. Fundamental provides the token for your organization.
- Permissions to create an EC2 instance, a security group, and an IAM role/instance profile in the account.

## Usage

From this directory:

```bash
# Start: provisions the jumpbox, installs the SDK, and opens a shell (SSM by default).
CLOUDSMITH_API_KEY=<token> AWS_PROFILE=<your-profile> ./start-model-test.sh <deployment-name> <region>
```

To connect over SSH instead (no Session Manager plugin required):

```bash
CLOUDSMITH_API_KEY=<token> AWS_PROFILE=<your-profile> ACCESS_MODE=ssh \
  ./start-model-test.sh <deployment-name> <region>
```

Once you are in the shell, run the prebuilt NEXUS smoke test:

```bash
nexus-test
```

It trains and predicts a small classifier and prints:

```
trained_model_id: <id>
accuracy: <float>
```

To iterate on your own test:

```bash
source /opt/fundamental/venv/bin/activate
vi /opt/fundamental/nexus_test.py
python /opt/fundamental/nexus_test.py
```

When you are done, `exit` the shell, then tear everything down:

```bash
AWS_PROFILE=<your-profile> ./stop-model-test.sh <deployment-name> <region>
```

The deployment name is the `DeploymentName` you deployed the stack with (the API NLB and exports are named after it). If you are unsure:

```bash
aws cloudformation list-exports --region <region> \
  --query "Exports[?ends_with(Name, '-RestApiEndpoint')].[Name,Value]" --output table
```

### Options (environment variables)

| Variable | Default | Purpose |
|----------|---------|---------|
| `CONSUMER_VPCE_ID` | auto-discovered | Pin the jumpbox to a specific registered consumer `execute-api` VPC endpoint. By default the script picks the first registered endpoint that is not the platform VPC endpoint. |
| `CLOUDSMITH_API_KEY` | (required) | Cloudsmith token used to install `fundamental-client` from `dl.cloudsmith.io` (not public PyPI). Fundamental provides a per-customer token - ask your Fundamental contact. |
| `SDK_VERSION` | `0.15.0` | `fundamental-client` version to install. Pinned so the client matches the deployed API; set `SDK_VERSION=""` for the latest, or `SDK_VERSION=x.y.z` for another pin. |
| `ACCESS_MODE` | `ssm` | `ssm` connects over Systems Manager (no public IP / SSH key); `ssh` launches in a public subnet with a key pair and connects over SSH. |
| `KEY_NAME` | `fundamental-model-test-key` | (SSH mode) EC2 key pair name; created if missing. |
| `KEY_FILE` | `./<KEY_NAME>.pem` | (SSH mode) Local path to the private key, written when the key pair is created. |
| `SSH_CIDR` | your detected IP `/32` | (SSH mode) CIDR allowed inbound on port 22. |
| `SSH_SUBNET_ID` | auto-discovered public subnet | (SSH mode) Public subnet to launch the jumpbox in. |
| `INSTANCE_TYPE` | `t4g.small` | Jumpbox instance type. The script auto-selects the matching Amazon Linux 2023 AMI architecture. |

Region may be passed as the second argument or via `AWS_REGION` / `AWS_DEFAULT_REGION`.

## Notes and troubleshooting

- **Re-running `start` is safe.** It reuses the existing jumpbox for the same deployment instead of creating a duplicate.
- **`instance never came Online in SSM`:** the consumer VPC has no SSM path. Add `ssm` / `ssmmessages` / `ec2messages` interface endpoints (or NAT) to that VPC, or switch to `ACCESS_MODE=ssh`, then re-run.
- **Bootstrap failed fetching packages:** either `CLOUDSMITH_API_KEY` is wrong/expired, or the consumer VPC cannot reach `dl.cloudsmith.io` / `pypi.org`. Check the token and that the subnet has a NAT path, then re-run.
- **`AccessDeniedException` / `403` from the API:** the jumpbox is not in a registered consumer VPC, or the instance role lost the invoke policy. Confirm the consumer endpoint is in the API's `vpcEndpointIds`, and that the deployment exports `*-ApiGatewayInvokePolicyArn`.
- **Cannot SSH to the jumpbox (SSH mode):** port 22 is open only to `SSH_CIDR` (your detected IP at start time). If your IP changed, re-run with `SSH_CIDR=<your-ip>/32`, or set `SSH_SUBNET_ID` to a reachable public subnet.
- **Cost:** the jumpbox is a small instance that exists only between `start` and `stop`. Always run `stop` when finished.
- **`start` left a jumpbox running but you closed the terminal:** re-run `start` to reopen the shell to the same instance, or run `stop-model-test.sh` to clean it up.
