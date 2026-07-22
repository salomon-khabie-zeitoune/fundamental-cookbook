#!/bin/bash
# ==============================================================================
# Fundamental Platform - Stop Cluster Debug Access
# ==============================================================================
#
# USAGE:
#   ./stop-debug-access.sh <cluster-name> [region]
#
# Tears down everything start-debug-access.sh created: the relay instance, the
# 443 ingress rule it added to the cluster SG, the debug security group, the
# kubeconfig context, and (if no other relay remains) the SSM instance profile.
# ==============================================================================

set -euo pipefail

CLUSTER="${1:?usage: stop-debug-access.sh <cluster-name> [region]}"
REGION="${2:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
[ -n "${REGION}" ] || { echo "ERROR: set the region (arg 2, or AWS_REGION)"; exit 1; }

ROLE_NAME="fundamental-debug-ssm-role"
PROFILE_NAME="fundamental-debug-ssm-profile"
SG_NAME="fundamental-cluster-debug-sg"
TAG_KEY="fundamental-cluster-debug"

echo "=============================================="
echo "Tearing down cluster debug access"
echo "  Cluster: ${CLUSTER}"
echo "  Region:  ${REGION}"
echo "=============================================="

# 1. Terminate the relay instance(s) for this cluster and wait until gone
echo ""
echo "1. Terminating relay instance(s)..."
IIDS="$(aws ec2 describe-instances --region "${REGION}" \
  --filters "Name=tag:${TAG_KEY},Values=${CLUSTER}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text || true)"
if [ -n "${IIDS}" ]; then
  echo "   ${IIDS}"
  aws ec2 terminate-instances --region "${REGION}" --instance-ids ${IIDS} >/dev/null
  aws ec2 wait instance-terminated --region "${REGION}" --instance-ids ${IIDS}
else
  echo "   none found"
fi

# 2. Remove the 443 ingress rule and delete the debug security group
echo ""
echo "2. Removing debug security group..."
VPC_ID="$(aws eks describe-cluster --name "${CLUSTER}" --region "${REGION}" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || true)"
CLUSTER_SG="$(aws eks describe-cluster --name "${CLUSTER}" --region "${REGION}" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text 2>/dev/null || true)"
SG_ID="$(aws ec2 describe-security-groups --region "${REGION}" \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [ "${SG_ID}" != "None" ] && [ -n "${SG_ID}" ]; then
  if [ "${CLUSTER_SG}" != "None" ] && [ -n "${CLUSTER_SG}" ]; then
    aws ec2 revoke-security-group-ingress --region "${REGION}" \
      --group-id "${CLUSTER_SG}" --protocol tcp --port 443 --source-group "${SG_ID}" >/dev/null 2>&1 || true
  fi
  aws ec2 delete-security-group --region "${REGION}" --group-id "${SG_ID}" >/dev/null 2>&1 || true
  echo "   deleted ${SG_ID}"
else
  echo "   none found"
fi

# 3. Delete the SSM instance profile/role only if no other relay still uses it
echo ""
echo "3. Cleaning up SSM instance profile..."
OTHER="$(aws ec2 describe-instances --region "${REGION}" \
  --filters "Name=tag:Name,Values=fundamental-cluster-debug" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text || true)"
if [ -z "${OTHER}" ]; then
  if aws iam get-instance-profile --instance-profile-name "${PROFILE_NAME}" >/dev/null 2>&1; then
    aws iam remove-role-from-instance-profile --instance-profile-name "${PROFILE_NAME}" --role-name "${ROLE_NAME}" 2>/dev/null || true
    aws iam delete-instance-profile --instance-profile-name "${PROFILE_NAME}" 2>/dev/null || true
  fi
  if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
    aws iam detach-role-policy --role-name "${ROLE_NAME}" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
    aws iam delete-role --role-name "${ROLE_NAME}" 2>/dev/null || true
  fi
  echo "   removed"
else
  echo "   kept (other relays still present: ${OTHER})"
fi

# 4. Drop the kubeconfig context
echo ""
echo "4. Removing kubeconfig context..."
ARN="$(aws eks describe-cluster --name "${CLUSTER}" --region "${REGION}" --query 'cluster.arn' --output text 2>/dev/null || true)"
if [ "${ARN}" != "None" ] && [ -n "${ARN}" ]; then
  kubectl config delete-context "${ARN}" >/dev/null 2>&1 || true
  kubectl config delete-cluster "${ARN}" >/dev/null 2>&1 || true
  kubectl config unset "users.${ARN}" >/dev/null 2>&1 || true
fi
echo "   done"

echo ""
echo "=============================================="
echo "Teardown complete."
echo "=============================================="
