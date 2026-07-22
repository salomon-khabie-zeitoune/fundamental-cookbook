#!/bin/bash
# ==============================================================================
# Fundamental Platform - Create CloudFormation Service Role
# ==============================================================================
#
# USAGE:
#   ./create-role.sh [ROLE_NAME]
#
# EXAMPLE:
#   ./create-role.sh FundamentalPlatform-CFServiceRole
#
# The permission set is split across several files in policies/. Their combined
# size exceeds the 10,240-char limit for inline role policies, so each file is
# created as a CUSTOMER-MANAGED policy (separate 6 KB limit each) and attached
# to the role individually.
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLE_NAME="${1:-FundamentalPlatform-CFServiceRole}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

echo "=============================================="
echo "Creating CloudFormation Service Role"
echo "  Role:    ${ROLE_NAME}"
echo "  Account: ${ACCOUNT_ID}"
echo "=============================================="

# Step 1: the role (idempotent)
echo ""
echo "Step 1: Creating IAM role..."
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "  Role already exists, reusing it."
else
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "file://${SCRIPT_DIR}/trust-policy.json" \
    --description "CloudFormation service role for deploying Fundamental Platform" \
    --tags Key=Purpose,Value=CloudFormationServiceRole Key=Platform,Value=fundamental >/dev/null
fi

# Step 2: remove any legacy inline policies left by older versions of this script
echo ""
echo "Step 2: Clearing legacy inline policies (if any)..."
for inline in $(aws iam list-role-policies --role-name "${ROLE_NAME}" --query 'PolicyNames[]' --output text); do
  echo "  - Removing inline: ${inline}"
  aws iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name "${inline}"
done

# Step 3: one customer-managed policy per file, attached to the role
echo ""
echo "Step 3: Creating and attaching managed policies..."
for policy_file in "${SCRIPT_DIR}/policies/"*.json; do
  area="$(basename "${policy_file}" .json | sed 's/^[0-9]*-//')"
  policy_name="${ROLE_NAME}-${area}"
  policy_arn="arn:aws:iam::${ACCOUNT_ID}:policy/${policy_name}"

  if aws iam get-policy --policy-arn "${policy_arn}" >/dev/null 2>&1; then
    echo "  - Updating: ${policy_name}"
    # Managed policies keep at most 5 versions; drop the oldest non-default first.
    version_count="$(aws iam list-policy-versions --policy-arn "${policy_arn}" --query 'length(Versions)' --output text)"
    if [ "${version_count}" -ge 5 ]; then
      oldest="$(aws iam list-policy-versions --policy-arn "${policy_arn}" \
        --query 'Versions[?IsDefaultVersion==`false`]|[-1].VersionId' --output text)"
      aws iam delete-policy-version --policy-arn "${policy_arn}" --version-id "${oldest}"
    fi
    aws iam create-policy-version --policy-arn "${policy_arn}" \
      --policy-document "file://${policy_file}" --set-as-default >/dev/null
  else
    echo "  - Creating: ${policy_name}"
    aws iam create-policy --policy-name "${policy_name}" \
      --policy-document "file://${policy_file}" \
      --description "Fundamental Platform CF service role (${area})" \
      --tags Key=Platform,Value=fundamental >/dev/null
  fi
  aws iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${policy_arn}"
done

ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)"

echo ""
echo "=============================================="
echo "SUCCESS - Role Created"
echo "=============================================="
echo ""
echo "Role ARN:"
echo "  ${ROLE_ARN}"
echo ""
echo "To deploy the Fundamental Platform stack:"
echo ""
echo "  aws cloudformation create-stack \\"
echo "    --stack-name <your-deployment-name> \\"
echo "    --template-url <template-url> \\"
echo "    --capabilities CAPABILITY_NAMED_IAM \\"
echo "    --role-arn ${ROLE_ARN} \\"
echo "    --parameters ..."
echo ""
