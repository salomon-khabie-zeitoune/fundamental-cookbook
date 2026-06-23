#!/bin/bash
# ==============================================================================
# Fundamental Platform - Start Cluster Debug Access
# ==============================================================================
#
# USAGE:
#   ./start-debug-access.sh <cluster-name> [region]
#
# EXAMPLE:
#   AWS_PROFILE=my-profile ./start-debug-access.sh fundamental-eks us-west-1
#
# Spins up a tiny SSM-managed relay instance inside the platform VPC, points a
# kubeconfig context at it, and opens an SSM port-forward to the private EKS
# API. kubectl then runs on YOUR laptop through the tunnel - no NAT, no SSH,
# no VPN, and nothing is installed on the relay box.
#
# Re-running reuses an existing relay for the same cluster. Tear it all down
# with ./stop-debug-access.sh.
# ==============================================================================

set -euo pipefail

CLUSTER="${1:?usage: start-debug-access.sh <cluster-name> [region]}"
REGION="${2:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
[ -n "${REGION}" ] || { echo "ERROR: set the region (arg 2, or AWS_REGION)"; exit 1; }

LOCAL_PORT="${LOCAL_PORT:-8443}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t4g.small}"

ROLE_NAME="fundamental-debug-ssm-role"
PROFILE_NAME="fundamental-debug-ssm-profile"
SG_NAME="fundamental-cluster-debug-sg"
TAG_KEY="fundamental-cluster-debug"

echo "=============================================="
echo "Fundamental Platform - Cluster Debug Access"
echo "  Cluster: ${CLUSTER}"
echo "  Region:  ${REGION}"
echo "=============================================="

# ------------------------------------------------------------------------------
# 1. Discover the cluster's VPC, security group, endpoint and a private subnet
# ------------------------------------------------------------------------------
echo ""
echo "1. Reading cluster networking..."
read -r VPC_ID CLUSTER_SG ENDPOINT <<<"$(aws eks describe-cluster --name "${CLUSTER}" --region "${REGION}" \
  --query '[cluster.resourcesVpcConfig.vpcId, cluster.resourcesVpcConfig.clusterSecurityGroupId, cluster.endpoint]' \
  --output text)"
EKS_HOST="${ENDPOINT#https://}"

SUBNET_ID="$(aws eks describe-cluster --name "${CLUSTER}" --region "${REGION}" \
  --query 'cluster.resourcesVpcConfig.subnetIds[0]' --output text)"

echo "   VPC:      ${VPC_ID}"
echo "   ClusterSG:${CLUSTER_SG}"
echo "   Subnet:   ${SUBNET_ID}"
echo "   EKS host: ${EKS_HOST}"

# ------------------------------------------------------------------------------
# 2. Instance profile with only AmazonSSMManagedInstanceCore (idempotent)
# ------------------------------------------------------------------------------
echo ""
echo "2. Ensuring SSM instance profile..."
if ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  aws iam create-role --role-name "${ROLE_NAME}" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --description "Fundamental Platform cluster debug relay" \
    --tags Key=Platform,Value=fundamental >/dev/null
  aws iam attach-role-policy --role-name "${ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
fi
if ! aws iam get-instance-profile --instance-profile-name "${PROFILE_NAME}" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "${PROFILE_NAME}" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "${PROFILE_NAME}" --role-name "${ROLE_NAME}"
fi

# ------------------------------------------------------------------------------
# 3. Debug security group + 443 ingress on the cluster SG (idempotent)
# ------------------------------------------------------------------------------
echo ""
echo "3. Ensuring debug security group..."
SG_ID="$(aws ec2 describe-security-groups --region "${REGION}" \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [ "${SG_ID}" = "None" ] || [ -z "${SG_ID}" ]; then
  SG_ID="$(aws ec2 create-security-group --region "${REGION}" \
    --group-name "${SG_NAME}" --vpc-id "${VPC_ID}" \
    --description "Fundamental cluster debug relay (SSM port-forward)" \
    --query 'GroupId' --output text)"
fi
echo "   DebugSG:  ${SG_ID}"
# allow the relay to reach the private EKS API; harmless if it already exists
aws ec2 authorize-security-group-ingress --region "${REGION}" \
  --group-id "${CLUSTER_SG}" --protocol tcp --port 443 --source-group "${SG_ID}" \
  >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 4. Find or launch the relay instance
# ------------------------------------------------------------------------------
echo ""
echo "4. Finding or launching the relay instance..."
IID="$(aws ec2 describe-instances --region "${REGION}" \
  --filters "Name=tag:${TAG_KEY},Values=${CLUSTER}" "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)"

if [ "${IID}" = "None" ] || [ -z "${IID}" ]; then
  ARCH="$(aws ec2 describe-instance-types --region "${REGION}" --instance-types "${INSTANCE_TYPE}" \
    --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures[0]' --output text)"
  AMI="$(aws ssm get-parameter --region "${REGION}" \
    --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${ARCH}" \
    --query 'Parameter.Value' --output text)"
  echo "   Launching ${INSTANCE_TYPE} (${ARCH}) from ${AMI}..."
  for attempt in 1 2 3 4 5; do
    IID="$(aws ec2 run-instances --region "${REGION}" \
      --image-id "${AMI}" --instance-type "${INSTANCE_TYPE}" \
      --subnet-id "${SUBNET_ID}" --security-group-ids "${SG_ID}" \
      --no-associate-public-ip-address \
      --iam-instance-profile "Name=${PROFILE_NAME}" \
      --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=fundamental-cluster-debug},{Key=${TAG_KEY},Value=${CLUSTER}}]" \
      --query 'Instances[0].InstanceId' --output text 2>/dev/null || true)"
    [ -n "${IID}" ] && [ "${IID#i-}" != "${IID}" ] && break
    echo "   instance profile not ready yet, retrying (${attempt}/5)..."
    sleep 3
  done
  [ "${IID#i-}" != "${IID}" ] || { echo "ERROR: failed to launch relay instance"; exit 1; }
  aws ec2 wait instance-running --region "${REGION}" --instance-ids "${IID}"
fi
echo "   Instance: ${IID}"

echo "   Waiting for the SSM agent to register..."
for _ in $(seq 1 60); do
  PING="$(aws ssm describe-instance-information --region "${REGION}" \
    --filters "Key=InstanceIds,Values=${IID}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
  [ "${PING}" = "Online" ] && break
  sleep 5
done
[ "${PING}" = "Online" ] || { echo "ERROR: instance never came Online in SSM"; exit 1; }
echo "   SSM: Online"

# ------------------------------------------------------------------------------
# 5. kubeconfig pointed at the tunnel, with the correct cert SNI
# ------------------------------------------------------------------------------
echo ""
echo "5. Configuring kubeconfig..."
aws eks update-kubeconfig --name "${CLUSTER}" --region "${REGION}" >/dev/null
CTX="$(kubectl config current-context)"
ENTRY="$(kubectl config view -o "jsonpath={.contexts[?(@.name=='${CTX}')].context.cluster}")"
kubectl config set-cluster "${ENTRY}" --server="https://localhost:${LOCAL_PORT}" >/dev/null
kubectl config set-cluster "${ENTRY}" --tls-server-name="${EKS_HOST}" >/dev/null
echo "   Context:  ${CTX}"

# ------------------------------------------------------------------------------
# 6. Open the tunnel (blocks until Ctrl-C)
# ------------------------------------------------------------------------------
cat <<EOF

==============================================
Tunnel is opening on localhost:${LOCAL_PORT}.
In ANOTHER terminal (same AWS profile not required), run:

  kubectl get nodes

Press Ctrl-C here to close the tunnel. The relay instance stays up;
run ./stop-debug-access.sh ${CLUSTER} ${REGION} to delete everything.
==============================================

EOF

exec aws ssm start-session --region "${REGION}" --target "${IID}" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${EKS_HOST}\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"
