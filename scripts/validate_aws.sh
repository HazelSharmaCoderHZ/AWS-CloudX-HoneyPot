#!/bin/bash
# validate_aws.sh — Read-only pre-flight checks for real AWS deployment.
#
# Verifies region, resource names, AWS identity, and required permissions.
# Creates NO resources. Safe to run at any time.
#
# Usage:
#   AWS_MODE=real ./scripts/validate_aws.sh
#
# Exit code 0 = validation passed, safe to deploy.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [[ "$AWS_MODE" != "real" ]]; then
  echo "ERROR: validate_aws.sh requires AWS_MODE=real (got '$AWS_MODE')."
  echo "For LocalStack mode, validation is handled by docker compose up."
  exit 1
fi

FAIL=0

# ── 1. Region validation ────────────────────────────────────────────────────
REGION_PATTERN='^[a-z]{2}-[a-z]+-[0-9]+$'
if [[ "$AWS_REGION" =~ $REGION_PATTERN ]]; then
  echo "OK: Region format valid: $AWS_REGION"
else
  echo "FAIL: AWS_REGION '$AWS_REGION' does not match expected pattern (e.g. us-east-1, eu-west-1)"
  FAIL=1
fi

# ── 2. Resource name validation ─────────────────────────────────────────────
NAME_PATTERN='^[a-zA-Z0-9._-]+$'
for name in "$HAA_S3_BUCKET" "$HAA_DYNAMODB_TABLE" "$HAA_IAM_ROLE" "$HAA_PARSER_LAMBDA" "$HAA_CLOUDWATCH_LAMBDA"; do
  if [[ "$name" =~ $NAME_PATTERN ]]; then
    echo "OK: Resource name valid: $name"
  else
    echo "FAIL: Resource name invalid: '$name'"
    FAIL=1
  fi
done

# ── 3. AWS identity ─────────────────────────────────────────────────────────
echo ""
echo "Checking AWS identity..."
if ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) && [[ -n "$ACCOUNT_ID" ]]; then
  ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)
  echo "OK: Account=$ACCOUNT_ID  Arn=$ARN"
else
  echo "FAIL: aws sts get-caller-identity failed. Check credentials (env, ~/.aws/credentials, or IAM role)."
  FAIL=1
fi

# ── 4. Required permissions (read-only probes — no resources created) ───────
echo ""
echo "Checking required permissions (read-only probes)..."

check_perm() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "OK:   $desc"
  else
    echo "FAIL: $desc"
    FAIL=1
  fi
}

check_perm "dynamodb:ListTables"        aws dynamodb list-tables --region "$AWS_REGION" --max-items 1
check_perm "s3:ListAllMyBuckets"        aws s3api list-buckets --region "$AWS_REGION" 2>/dev/null \
  || { echo "WARN: s3 list-buckets failed (may be restricted by SCP/sandbox)"; }
check_perm "lambda:ListFunctions"       aws lambda list-functions --region "$AWS_REGION" --max-items 1
check_perm "iam:ListRoles"              aws iam list-roles --region "$AWS_REGION" --max-items 1 2>/dev/null \
  || { echo "WARN: iam list-roles failed (may be restricted by SCP/sandbox)"; }

# Resources that may not exist yet — probe is informational only.
if aws iam get-role --role-name "$HAA_IAM_ROLE" >/dev/null 2>&1; then
  echo "INFO: IAM role $HAA_IAM_ROLE already exists"
else
  echo "INFO: IAM role $HAA_IAM_ROLE not found (will be created during deploy)"
fi

if aws lambda get-function --function-name "$HAA_PARSER_LAMBDA" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "INFO: Lambda $HAA_PARSER_LAMBDA already exists"
else
  echo "INFO: Lambda $HAA_PARSER_LAMBDA not found (will be created during deploy)"
fi

echo ""
if [[ "$FAIL" -ne 0 ]]; then
  echo "Validation FAILED with $FAIL error(s). Review the messages above."
  exit 1
fi
echo "Validation PASSED. Safe to run: AWS_MODE=real ./scripts/deploy_aws.sh"