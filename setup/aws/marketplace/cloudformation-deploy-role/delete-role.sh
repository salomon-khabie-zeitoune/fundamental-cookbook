#!/bin/bash
# ==============================================================================
# Fundamental Platform - Delete CloudFormation Service Role
# ==============================================================================
#
# USAGE:
#   ./delete-role.sh [ROLE_NAME]
#
# Detaches and deletes the customer-managed policies this role's create script
# made (named <ROLE_NAME>-*), removes any legacy inline policies, then deletes
# the role.
# ==============================================================================

set -e

ROLE_NAME="${1:-FundamentalPlatform-CFServiceRole}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

echo "=============================================="
echo "Deleting CloudFormation Service Role"
echo "  Role:    ${ROLE_NAME}"
echo "  Account: ${ACCOUNT_ID}"
echo "=============================================="

# Step 1: detach + delete the managed policies created for this role
echo ""
echo "Step 1: Detaching and deleting managed policies..."
for arn in $(aws iam list-attached-role-policies --role-name "${ROLE_NAME}" --query 'AttachedPolicies[].PolicyArn' --output text); do
  echo "  - Detaching: ${arn}"
  aws iam detach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${arn}"
  # Only delete policies this script owns (named after the role, in this account).
  case "${arn}" in
    "arn:aws:iam::${ACCOUNT_ID}:policy/${ROLE_NAME}-"*)
      for v in $(aws iam list-policy-versions --policy-arn "${arn}" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
        aws iam delete-policy-version --policy-arn "${arn}" --version-id "${v}"
      done
      echo "    deleting policy ${arn}"
      aws iam delete-policy --policy-arn "${arn}"
      ;;
  esac
done

# Step 2: remove any legacy inline policies
echo ""
echo "Step 2: Removing inline policies (if any)..."
for inline in $(aws iam list-role-policies --role-name "${ROLE_NAME}" --query 'PolicyNames[]' --output text); do
  echo "  - Removing inline: ${inline}"
  aws iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name "${inline}"
done

# Step 3: delete the role
echo ""
echo "Step 3: Deleting role..."
aws iam delete-role --role-name "${ROLE_NAME}"

echo ""
echo "=============================================="
echo "SUCCESS - Role Deleted"
echo "=============================================="
