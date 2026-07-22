#!/bin/bash
# ==============================================================================
# Fundamental Platform - Stop Model Test Jumpbox
# ==============================================================================
#
# USAGE:
#   ./stop-model-test.sh <deployment-name> [region]
#
# Tears down everything start-model-test.sh created: the jumpbox instance, the
# jumpbox security group, the SSH key pair (if one was created for this
# deployment), and (if no other jumpbox remains) the SSM/API-invoke instance
# profile and role.
# ==============================================================================

set -euo pipefail

DEPLOYMENT="${1:?usage: stop-model-test.sh <deployment-name> [region]}"
REGION="${2:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
[ -n "${REGION}" ] || { echo "ERROR: set the region (arg 2, or AWS_REGION)"; exit 1; }

ROLE_NAME="fundamental-model-test-role"
PROFILE_NAME="fundamental-model-test-profile"
SG_NAME="fundamental-model-test-sg"
TAG_KEY="fundamental-model-test"
KEY_NAME="${KEY_NAME:-fundamental-model-test-key}"

echo "=============================================="
echo "Tearing down model test jumpbox"
echo "  Deployment: ${DEPLOYMENT}"
echo "  Region:     ${REGION}"
echo "=============================================="

# 1. Terminate the jumpbox(es) for this deployment and wait until gone
echo ""
echo "1. Terminating jumpbox instance(s)..."
IIDS="$(aws ec2 describe-instances --region "${REGION}" \
  --filters "Name=tag:${TAG_KEY},Values=${DEPLOYMENT}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text || true)"
if [ -n "${IIDS}" ]; then
  echo "   ${IIDS}"
  aws ec2 terminate-instances --region "${REGION}" --instance-ids ${IIDS} >/dev/null
  aws ec2 wait instance-terminated --region "${REGION}" --instance-ids ${IIDS}
else
  echo "   none found"
fi

# 2. Delete the jumpbox security group
echo ""
echo "2. Removing jumpbox security group..."
SG_ID="$(aws ec2 describe-security-groups --region "${REGION}" \
  --filters "Name=group-name,Values=${SG_NAME}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)"
if [ "${SG_ID}" != "None" ] && [ -n "${SG_ID}" ]; then
  aws ec2 delete-security-group --region "${REGION}" --group-id "${SG_ID}" >/dev/null 2>&1 || true
  echo "   deleted ${SG_ID}"
else
  echo "   none found"
fi

# 3. Delete the SSH key pair if we created one for this deployment (tagged)
echo ""
echo "3. Removing SSH key pair (if any)..."
KP="$(aws ec2 describe-key-pairs --region "${REGION}" \
  --filters "Name=key-name,Values=${KEY_NAME}" "Name=tag:${TAG_KEY},Values=${DEPLOYMENT}" \
  --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || true)"
if [ "${KP}" != "None" ] && [ -n "${KP}" ]; then
  aws ec2 delete-key-pair --region "${REGION}" --key-name "${KP}" >/dev/null 2>&1 || true
  echo "   deleted key pair ${KP} (remove the local ${KEY_NAME}.pem yourself if you no longer need it)"
else
  echo "   none found"
fi

# 4. Delete the instance profile/role only if no other jumpbox still uses it
echo ""
echo "4. Cleaning up instance profile..."
OTHER="$(aws ec2 describe-instances --region "${REGION}" \
  --filters "Name=tag:Name,Values=fundamental-model-test" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text || true)"
if [ -z "${OTHER}" ]; then
  if aws iam get-instance-profile --instance-profile-name "${PROFILE_NAME}" >/dev/null 2>&1; then
    aws iam remove-role-from-instance-profile --instance-profile-name "${PROFILE_NAME}" --role-name "${ROLE_NAME}" 2>/dev/null || true
    aws iam delete-instance-profile --instance-profile-name "${PROFILE_NAME}" 2>/dev/null || true
  fi
  if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
    # Detach every managed policy (SSM core + the deployment's invoke policy) before deleting.
    for arn in $(aws iam list-attached-role-policies --role-name "${ROLE_NAME}" \
      --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
      aws iam detach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${arn}" 2>/dev/null || true
    done
    aws iam delete-role --role-name "${ROLE_NAME}" 2>/dev/null || true
  fi
  echo "   removed"
else
  echo "   kept (other jumpboxes still present: ${OTHER})"
fi

echo ""
echo "=============================================="
echo "Teardown complete."
echo "=============================================="
