#!/bin/bash
# ==============================================================================
# Fundamental Platform - Start Model Test Jumpbox
# ==============================================================================
#
# USAGE:
#   ./start-model-test.sh <deployment-name> [region]
#
# EXAMPLE:
#   CLOUDSMITH_API_KEY=<token> AWS_PROFILE=my-profile ./start-model-test.sh fundamental us-west-1
#
# Spins up a tiny jumpbox INSIDE A CONSUMER VPC (one whose execute-api endpoint
# is registered with the private API Gateway), attaches an instance profile that
# can invoke the API, installs the Fundamental SDK, and drops you into a shell
# with FUNDAMENTAL_API_URL and AWS_REGION already set. From there you run the
# NEXUS smoke test the same way your own application does: IAM SigV4 auth
# through the private API Gateway.
#
# Access modes (ACCESS_MODE):
#   ssm  (default) - connect over AWS Systems Manager. No public IP, no SSH key.
#                    Needs the Session Manager plugin locally and SSM
#                    connectivity in the consumer VPC (SSM endpoints or NAT).
#   ssh            - connect over SSH with a key pair. The jumpbox launches in a
#                    public subnet with a public IP and port-22 ingress locked to
#                    your IP. Use this when you do not have SSM.
#
# Re-running reuses an existing jumpbox for the same deployment. Tear it all
# down with ./stop-model-test.sh.
# ==============================================================================

set -euo pipefail

DEPLOYMENT="${1:?usage: start-model-test.sh <deployment-name> [region]}"
REGION="${2:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
[ -n "${REGION}" ] || { echo "ERROR: set the region (arg 2, or AWS_REGION)"; exit 1; }

INSTANCE_TYPE="${INSTANCE_TYPE:-t4g.small}"

# The Fundamental SDK installs from a token-gated Cloudsmith index, not public PyPI.
CLOUDSMITH_API_KEY="${CLOUDSMITH_API_KEY:-}"
[ -n "${CLOUDSMITH_API_KEY}" ] || { echo "ERROR: set CLOUDSMITH_API_KEY (Cloudsmith token used to install fundamental-client; ask the SDK owners if you do not have one)."; exit 1; }

# Pin the SDK to a version compatible with the deployed API (the latest client
# can require a newer API). Override with SDK_VERSION=x.y.z or SDK_VERSION="" for latest.
SDK_VERSION="${SDK_VERSION:-0.15.0}"

# Connection mode: ssm (default) or ssh.
ACCESS_MODE="${ACCESS_MODE:-ssm}"
case "${ACCESS_MODE}" in
  ssm|ssh) ;;
  *) echo "ERROR: ACCESS_MODE must be 'ssm' or 'ssh' (got '${ACCESS_MODE}')."; exit 1 ;;
esac

# SSH-mode settings (ignored in ssm mode).
KEY_NAME="${KEY_NAME:-fundamental-model-test-key}"
KEY_FILE="${KEY_FILE:-./${KEY_NAME}.pem}"

ROLE_NAME="fundamental-model-test-role"
PROFILE_NAME="fundamental-model-test-profile"
SG_NAME="fundamental-model-test-sg"
TAG_KEY="fundamental-model-test"

# Read a CloudFormation export by name. list-exports paginates and the CLI
# applies --query per page, so "| [0]" would emit a stray "None" from the
# non-matching page. Query without [0] and strip blank/None lines instead.
# Trailing `|| true`: when the export is missing, grep matches nothing and exits
# non-zero, which under `set -euo pipefail` would abort the script before the
# caller can report a helpful error. Return empty instead and let the caller check.
get_export() {
  aws cloudformation list-exports --region "${REGION}" \
    --query "Exports[?Name=='$1'].Value" --output text 2>/dev/null \
    | tr '\t' '\n' | grep -vE '^$|^None$' | head -n1 || true
}

echo "=============================================="
echo "Fundamental Platform - Model Test Jumpbox"
echo "  Deployment: ${DEPLOYMENT}"
echo "  Region:     ${REGION}"
echo "  Access:     ${ACCESS_MODE}"
echo "=============================================="

# ------------------------------------------------------------------------------
# 1. Resolve the API Gateway endpoint, invoke policy, and stack VPC endpoint
# ------------------------------------------------------------------------------
echo ""
echo "1. Reading deployment outputs..."
API_URL="$(get_export "${DEPLOYMENT}-RestApiEndpoint")"
REST_API_ID="$(get_export "${DEPLOYMENT}-RestApiId")"
INVOKE_POLICY_ARN="$(get_export "${DEPLOYMENT}-ApiGatewayInvokePolicyArn")"
STACK_VPCE="$(get_export "${DEPLOYMENT}-ExecuteApiInterfaceEndpointId")"

for pair in "RestApiEndpoint=${API_URL}" "RestApiId=${REST_API_ID}" "ApiGatewayInvokePolicyArn=${INVOKE_POLICY_ARN}"; do
  val="${pair#*=}"
  if [ -z "${val}" ] || [ "${val}" = "None" ]; then
    echo "ERROR: could not read CloudFormation export ${DEPLOYMENT}-${pair%%=*} in ${REGION}."
    echo "       Check the deployment name and that you are in the right account/region."
    exit 1
  fi
done
echo "   API URL:  ${API_URL}"
echo "   Rest API: ${REST_API_ID}"

# ------------------------------------------------------------------------------
# 2. Find a CONSUMER execute-api VPC endpoint (never the platform VPC), then
#    choose the subnet to launch in. SSM uses the endpoint's private subnet;
#    SSH needs a public subnet for inbound access.
# ------------------------------------------------------------------------------
echo ""
echo "2. Locating a consumer VPC endpoint..."
CONSUMER_VPCE="${CONSUMER_VPCE_ID:-}"
if [ -z "${CONSUMER_VPCE}" ]; then
  REGISTERED="$(aws apigateway get-rest-api --region "${REGION}" --rest-api-id "${REST_API_ID}" \
    --query 'endpointConfiguration.vpcEndpointIds' --output text 2>/dev/null || true)"
  for vpce in ${REGISTERED}; do
    [ "${vpce}" = "${STACK_VPCE}" ] && continue   # skip the platform VPC endpoint
    CONSUMER_VPCE="${vpce}"
    break
  done
fi

if [ -z "${CONSUMER_VPCE}" ] || [ "${CONSUMER_VPCE}" = "None" ]; then
  cat <<EOF
ERROR: no consumer VPC endpoint is registered with this private API.

The jumpbox must run in a consumer VPC (a VPC whose execute-api endpoint is
registered with the API Gateway), not in the Fundamental platform VPC.

Fix one of:
  - Register a consumer VPC: deploy consumer-vpc-endpoint.yaml in the consumer
    VPC, then add its endpoint id to the stack's ConsumerVpcEndpoint<N>Id param
    and update the deployment so the private API accepts it.
  - Or set CONSUMER_VPCE_ID=<vpce-id> to target a specific registered endpoint.
EOF
  exit 1
fi

read -r CONSUMER_VPC PRIVATE_SUBNET <<<"$(aws ec2 describe-vpc-endpoints --region "${REGION}" \
  --vpc-endpoint-ids "${CONSUMER_VPCE}" \
  --query 'VpcEndpoints[0].[VpcId, SubnetIds[0]]' --output text)"
[ -n "${PRIVATE_SUBNET}" ] && [ "${PRIVATE_SUBNET}" != "None" ] || { echo "ERROR: consumer endpoint ${CONSUMER_VPCE} has no subnet"; exit 1; }
echo "   Endpoint: ${CONSUMER_VPCE}"
echo "   VPC:      ${CONSUMER_VPC}"

if [ "${ACCESS_MODE}" = "ssh" ]; then
  LAUNCH_SUBNET="${SSH_SUBNET_ID:-}"
  if [ -z "${LAUNCH_SUBNET}" ]; then
    LAUNCH_SUBNET="$(aws ec2 describe-subnets --region "${REGION}" \
      --filters "Name=vpc-id,Values=${CONSUMER_VPC}" "Name=map-public-ip-on-launch,Values=true" \
      --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)"
  fi
  if [ -z "${LAUNCH_SUBNET}" ] || [ "${LAUNCH_SUBNET}" = "None" ]; then
    echo "ERROR: no public subnet found in ${CONSUMER_VPC} for SSH access."
    echo "       Set SSH_SUBNET_ID=<public-subnet> (one with an internet-gateway route),"
    echo "       or use the default SSM mode (unset ACCESS_MODE)."
    exit 1
  fi
else
  LAUNCH_SUBNET="${PRIVATE_SUBNET}"
fi
echo "   Subnet:   ${LAUNCH_SUBNET} (${ACCESS_MODE})"

# ------------------------------------------------------------------------------
# 3. Instance profile: SSM core + the deployment's API invoke policy (idempotent)
# ------------------------------------------------------------------------------
echo ""
echo "3. Ensuring instance profile (SSM + API invoke)..."
if ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role --role-name "${ROLE_NAME}" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --description "Fundamental Platform model test jumpbox" \
    --tags Key=Platform,Value=fundamental >/dev/null
  aws iam attach-role-policy --role-name "${ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
fi
# Attach the deployment's execute-api invoke policy (harmless if already attached).
aws iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${INVOKE_POLICY_ARN}" >/dev/null 2>&1 || true
if ! aws iam get-instance-profile --instance-profile-name "${PROFILE_NAME}" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "${PROFILE_NAME}" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "${PROFILE_NAME}" --role-name "${ROLE_NAME}"
fi

# ------------------------------------------------------------------------------
# 4. Jumpbox security group (default egress is all-allow). SSH mode also opens
#    port 22 to your IP.
# ------------------------------------------------------------------------------
echo ""
echo "4. Ensuring jumpbox security group..."
SG_ID="$(aws ec2 describe-security-groups --region "${REGION}" \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${CONSUMER_VPC}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [ "${SG_ID}" = "None" ] || [ -z "${SG_ID}" ]; then
  SG_ID="$(aws ec2 create-security-group --region "${REGION}" \
    --group-name "${SG_NAME}" --vpc-id "${CONSUMER_VPC}" \
    --description "Fundamental model test jumpbox" \
    --query 'GroupId' --output text)"
fi
echo "   JumpboxSG: ${SG_ID}"

if [ "${ACCESS_MODE}" = "ssh" ]; then
  SSH_CIDR="${SSH_CIDR:-}"
  if [ -z "${SSH_CIDR}" ]; then
    MYIP="$(curl -s --max-time 10 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
    [ -n "${MYIP}" ] || { echo "ERROR: could not detect your public IP; set SSH_CIDR=<x.x.x.x/32>."; exit 1; }
    SSH_CIDR="${MYIP}/32"
  fi
  echo "   Allowing SSH (22) from ${SSH_CIDR}"
  aws ec2 authorize-security-group-ingress --region "${REGION}" \
    --group-id "${SG_ID}" --protocol tcp --port 22 --cidr "${SSH_CIDR}" >/dev/null 2>&1 || true

  # Ensure a key pair we can connect with.
  if [ -f "${KEY_FILE}" ]; then
    echo "   Using existing key file ${KEY_FILE} (key pair ${KEY_NAME})"
  elif aws ec2 describe-key-pairs --region "${REGION}" --key-names "${KEY_NAME}" >/dev/null 2>&1; then
    echo "ERROR: key pair ${KEY_NAME} exists in AWS but ${KEY_FILE} is missing locally."
    echo "       Set KEY_FILE=<path-to-pem> or KEY_NAME=<another-name> and retry."
    exit 1
  else
    echo "   Creating key pair ${KEY_NAME} -> ${KEY_FILE}"
    aws ec2 create-key-pair --region "${REGION}" --key-name "${KEY_NAME}" \
      --tag-specifications "ResourceType=key-pair,Tags=[{Key=${TAG_KEY},Value=${DEPLOYMENT}}]" \
      --query 'KeyMaterial' --output text > "${KEY_FILE}"
    chmod 400 "${KEY_FILE}"
  fi
fi

# ------------------------------------------------------------------------------
# 5. The bootstrap that installs the SDK + smoke test on the jumpbox. Delivered
#    via SSM send-command (ssm mode) or over SSH (ssh mode); identical either way.
# ------------------------------------------------------------------------------
BOOTSTRAP="$(cat <<BOOT
set -euo pipefail
dnf install -y python3.11 python3.11-pip >/dev/null
mkdir -p /opt/fundamental
python3.11 -m venv --clear /opt/fundamental/venv
/opt/fundamental/venv/bin/pip install --upgrade pip >/dev/null
/opt/fundamental/venv/bin/pip install --extra-index-url "https://token:${CLOUDSMITH_API_KEY}@dl.cloudsmith.io/basic/fundamental/fundamental-client/python/simple/" "fundamental-client[aws-marketplace]${SDK_VERSION:+==${SDK_VERSION}}" numpy scikit-learn >/dev/null

cat > /opt/fundamental/nexus_test.py <<'PY'
import os

import numpy as np
from sklearn.datasets import make_classification
from sklearn.model_selection import train_test_split

from fundamental import FundamentalAWSMarketplaceClient, NEXUSClassifier, set_client

set_client(
    FundamentalAWSMarketplaceClient(
        aws_region=os.environ.get("AWS_REGION", "us-west-1"),
        api_url=os.environ["FUNDAMENTAL_API_URL"],
    )
)

X, y = make_classification(n_samples=200, n_features=10, n_classes=2, random_state=0)
X_train, X_test, y_train, y_test = (
    np.asarray(a) for a in train_test_split(X, y, test_size=0.25, random_state=0)
)

clf = NEXUSClassifier(mode="optimized")
clf.fit(X_train, y_train)
preds = clf.predict(X_test)

print("trained_model_id:", getattr(clf, "trained_model_id_", None))
print("accuracy:", float(np.mean(preds == y_test)))
PY

cat > /etc/profile.d/fundamental.sh <<ENV
export FUNDAMENTAL_API_URL="${API_URL}"
export AWS_REGION="${REGION}"
ENV

cat > /usr/local/bin/nexus-test <<'RUN'
#!/bin/bash
export FUNDAMENTAL_API_URL="${API_URL}"
export AWS_REGION="${REGION}"
exec /opt/fundamental/venv/bin/python /opt/fundamental/nexus_test.py "\$@"
RUN
chmod +x /usr/local/bin/nexus-test
chmod -R a+rX /opt/fundamental
BOOT
)"

# ------------------------------------------------------------------------------
# 6. Find or launch the jumpbox
# ------------------------------------------------------------------------------
echo ""
echo "5. Finding or launching the jumpbox..."
IID="$(aws ec2 describe-instances --region "${REGION}" \
  --filters "Name=tag:${TAG_KEY},Values=${DEPLOYMENT}" "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)"

if [ "${IID}" = "None" ] || [ -z "${IID}" ]; then
  if [ "${ACCESS_MODE}" = "ssh" ]; then
    NET_ARGS=(--associate-public-ip-address --key-name "${KEY_NAME}")
  else
    NET_ARGS=(--no-associate-public-ip-address)
  fi
  ARCH="$(aws ec2 describe-instance-types --region "${REGION}" --instance-types "${INSTANCE_TYPE}" \
    --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures[0]' --output text)"
  AMI="$(aws ssm get-parameter --region "${REGION}" \
    --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${ARCH}" \
    --query 'Parameter.Value' --output text)"
  echo "   Launching ${INSTANCE_TYPE} (${ARCH}) from ${AMI}..."
  for attempt in 1 2 3 4 5; do
    IID="$(aws ec2 run-instances --region "${REGION}" \
      --image-id "${AMI}" --instance-type "${INSTANCE_TYPE}" \
      --subnet-id "${LAUNCH_SUBNET}" --security-group-ids "${SG_ID}" \
      "${NET_ARGS[@]}" \
      --iam-instance-profile "Name=${PROFILE_NAME}" \
      --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=fundamental-model-test},{Key=${TAG_KEY},Value=${DEPLOYMENT}}]" \
      --query 'Instances[0].InstanceId' --output text 2>/dev/null || true)"
    [ -n "${IID}" ] && [ "${IID#i-}" != "${IID}" ] && break
    echo "   instance profile not ready yet, retrying (${attempt}/5)..."
    sleep 3
  done
  [ "${IID#i-}" != "${IID}" ] || { echo "ERROR: failed to launch jumpbox"; exit 1; }
  aws ec2 wait instance-running --region "${REGION}" --instance-ids "${IID}"
fi
echo "   Instance: ${IID}"

# ------------------------------------------------------------------------------
# 7. Provision the box and connect (mode-specific)
# ------------------------------------------------------------------------------
if [ "${ACCESS_MODE}" = "ssh" ]; then
  PUBLIC_IP="$(aws ec2 describe-instances --region "${REGION}" --instance-ids "${IID}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null || true)"
  [ -n "${PUBLIC_IP}" ] && [ "${PUBLIC_IP}" != "None" ] || { echo "ERROR: jumpbox has no public IP (is the subnet public?). Tear down with ./stop-model-test.sh."; exit 1; }
  echo "   Public IP: ${PUBLIC_IP}"

  echo "   Waiting for SSH..."
  SSH_OK=""
  for _ in $(seq 1 40); do
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
      -i "${KEY_FILE}" "ec2-user@${PUBLIC_IP}" true 2>/dev/null; then SSH_OK=1; break; fi
    sleep 5
  done
  [ -n "${SSH_OK}" ] || { echo "ERROR: could not reach ${PUBLIC_IP}:22. Check SSH_CIDR (${SSH_CIDR}) and that ${LAUNCH_SUBNET} is public."; exit 1; }

  echo ""
  echo "6. Installing the Fundamental SDK and smoke test over SSH (a few minutes)..."
  BOOT_FILE="$(mktemp)"
  printf '%s\n' "${BOOTSTRAP}" > "${BOOT_FILE}"
  if ! ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    -i "${KEY_FILE}" "ec2-user@${PUBLIC_IP}" 'sudo bash -s' < "${BOOT_FILE}"; then
    rm -f "${BOOT_FILE}"
    echo "ERROR: bootstrap over SSH failed."
    echo "Hint: bad/expired CLOUDSMITH_API_KEY, or the box lacks egress to dl.cloudsmith.io / pypi.org."
    exit 1
  fi
  rm -f "${BOOT_FILE}"
  echo "   Bootstrap complete."

  cat <<EOF

==============================================
Jumpbox ${IID} is ready in consumer VPC ${CONSUMER_VPC}.
Opening an SSH session. Once in, run:

  nexus-test                       # the prebuilt NEXUS smoke test

or iterate yourself:

  source /opt/fundamental/venv/bin/activate
  vi /opt/fundamental/nexus_test.py
  python /opt/fundamental/nexus_test.py

FUNDAMENTAL_API_URL and AWS_REGION are already set on the box.
Auth is IAM SigV4 via the jumpbox instance role.

Type 'exit' to leave. The jumpbox stays up; run
./stop-model-test.sh ${DEPLOYMENT} ${REGION} to delete everything.
==============================================

EOF
  exec ssh -o StrictHostKeyChecking=accept-new -i "${KEY_FILE}" "ec2-user@${PUBLIC_IP}"
fi

# --- ssm mode ---
echo "   Waiting for the SSM agent to register..."
PING=""
for _ in $(seq 1 60); do
  PING="$(aws ssm describe-instance-information --region "${REGION}" \
    --filters "Key=InstanceIds,Values=${IID}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
  [ "${PING}" = "Online" ] && break
  sleep 5
done
if [ "${PING}" != "Online" ]; then
  echo "ERROR: instance never came Online in SSM."
  echo "       The consumer VPC needs SSM connectivity (ssm/ssmmessages/ec2messages"
  echo "       endpoints or a NAT path), or use ACCESS_MODE=ssh. Tear down with"
  echo "       ./stop-model-test.sh."
  exit 1
fi
echo "   SSM: Online"

echo ""
echo "6. Installing the Fundamental SDK and smoke test (this can take a few minutes)..."
B64="$(printf '%s' "${BOOTSTRAP}" | base64 | tr -d '\n')"
CMD_ID="$(aws ssm send-command --region "${REGION}" \
  --instance-ids "${IID}" \
  --document-name AWS-RunShellScript \
  --comment "fundamental model test bootstrap" \
  --parameters "commands=[\"echo ${B64} | base64 -d > /tmp/boot.sh\",\"bash /tmp/boot.sh\"]" \
  --query 'Command.CommandId' --output text)"

STATUS=""
for _ in $(seq 1 90); do
  STATUS="$(aws ssm get-command-invocation --region "${REGION}" \
    --command-id "${CMD_ID}" --instance-id "${IID}" \
    --query 'Status' --output text 2>/dev/null || true)"
  [ "${STATUS}" = "Success" ] && break
  if [ "${STATUS}" = "Failed" ] || [ "${STATUS}" = "Cancelled" ] || [ "${STATUS}" = "TimedOut" ]; then
    echo "ERROR: bootstrap ${STATUS}. Last error output:"
    aws ssm get-command-invocation --region "${REGION}" --command-id "${CMD_ID}" --instance-id "${IID}" \
      --query 'StandardErrorContent' --output text 2>/dev/null | tail -20
    echo "Hint: bad/expired CLOUDSMITH_API_KEY, or the consumer VPC lacks egress to dl.cloudsmith.io / pypi.org. Tear down with ./stop-model-test.sh."
    exit 1
  fi
  sleep 5
done
[ "${STATUS}" = "Success" ] || { echo "ERROR: bootstrap did not finish in time (last status: ${STATUS})"; exit 1; }
echo "   Bootstrap complete."

cat <<EOF

==============================================
Jumpbox ${IID} is ready in consumer VPC ${CONSUMER_VPC}.
Opening an SSM shell. Once in, run:

  nexus-test                       # the prebuilt NEXUS smoke test

or iterate yourself:

  source /opt/fundamental/venv/bin/activate
  vi /opt/fundamental/nexus_test.py
  python /opt/fundamental/nexus_test.py

FUNDAMENTAL_API_URL and AWS_REGION are already exported in the shell.
Auth is IAM SigV4 via the jumpbox instance role.

Type 'exit' to leave the shell. The jumpbox stays up; run
./stop-model-test.sh ${DEPLOYMENT} ${REGION} to delete everything.
==============================================

EOF

exec aws ssm start-session --region "${REGION}" --target "${IID}"
