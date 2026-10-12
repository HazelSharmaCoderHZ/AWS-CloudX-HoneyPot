#!/bin/bash
# teardown_aws.sh  Safe, opt-in cleanup of real-AWS HaaS resources.
#
# SAFETY: By default this script is a DRY-RUN. It only prints what it WOULD do.
# Nothing is deleted unless you pass --confirm AND each destructive step is
# re-confirmed interactively (or --yes is used for non-interactive runs).
#
# Order of deletion (reverse of deploy):
#   1. Lambda event source mappings (DynamoDB stream -> CloudWatch Lambda)
#   2. Lambda functions (CowrieLogParser, LogDynamoDBToCloudWatch)
#   3. S3 bucket notifications (only the HaaS parser config)
#   4. IAM role (only if no attached policies remain)
#   5. DynamoDB table (ONLY if --empty-bucket is also given AND bucket is empty)
#
# The S3 bucket is NEVER deleted automatically. Buckets with data require an
# explicit --empty-bucket flag plus interactive confirmation.
#
# Usage:
#   AWS_MODE=real ./scripts/teardown_aws.sh                  # dry-run (default)
#   AWS_MODE=real ./scripts/teardown_aws.sh --confirm        # interactive
#   AWS_MODE=real ./scripts/teardown_aws.sh --confirm --yes  # non-interactive
#   AWS_MODE=real ./scripts/teardown_aws.sh --confirm --yes --empty-bucket
#
# Credentials come from the standard AWS CLI chain only. Never set keys here.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CONFIRM=0
YES=0
EMPTY_BUCKET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM=1; shift ;;
    --yes) YES=1; shift ;;
    --empty-bucket) EMPTY_BUCKET=1; shift ;;
    *) echo "Unknown argument: $1"; exit 2 ;;
  esac
done

if [[ "$AWS_MODE" != "real" ]]; then
  echo "ERROR: teardown_aws.sh requires AWS_MODE=real (got '$AWS_MODE')."
  echo "LocalStack teardown: docker compose down -v"
  exit 1
fi

AWS="$(command -v aws)"
if [[ -z "$AWS" ]]; then
  echo "ERROR: 'aws' CLI not found on PATH."
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [[ -z "$ACCOUNT_ID" ]]; then
  echo "ERROR: cannot determine AWS account id (sts get-caller-identity failed)."
  exit 1
fi

DRY_RUN=1
if [[ "$CONFIRM" -eq 1 ]]; then
  DRY_RUN=0
fi

log()  { echo "[teardown] $*"; }
run()  { if [[ "$DRY_RUN" -eq 1 ]]; then echo "DRY-RUN: would run: $*"; else log "$*"; "$@"; fi; }
info() { echo "  $*"; }

echo "+----------------------------------------------------------+"
echo "¦   HaaS  Real AWS teardown                             ¦"
echo "¦   Account: $ACCOUNT_ID  Region: $AWS_REGION            ¦"
echo "+----------------------------------------------------------+"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "*** DRY-RUN MODE (default). Nothing will be deleted. ***"
  echo "*** Pass --confirm to proceed (interactive). ***"
  echo ""
fi
# -- Ownership guard ---------------------------------------------------------
# Refuse to touch any resource that is not owned by this account.
require_owner() {
  local desc="$1"; shift
  local actual
  actual="$("$@" 2>/dev/null || echo "")"
  if [[ -n "$actual" && "$actual" != "$ACCOUNT_ID" ]]; then
    echo "ABORT: $desc reports owner $actual, not $ACCOUNT_ID. Refusing to modify foreign resource."
    exit 1
  fi
}

# -- Interactive confirm helper ----------------------------------------------
confirm() {
  local msg="$1"
  if [[ "$YES" -eq 1 ]]; then
    return 0
  fi
  read -r -p "$msg [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# -------------------------------------------------------------------------------
# 1. Remove Lambda event source mappings
# -------------------------------------------------------------------------------
log "Step 1 - DynamoDB stream event source mappings"

if aws lambda get-function --function-name "$HAA_CLOUDWATCH_LAMBDA" --region "$AWS_REGION" >/dev/null 2>&1; then
  MAPPINGS="$(aws lambda list-event-source-mappings --function-name "$HAA_CLOUDWATCH_LAMBDA" --region "$AWS_REGION" --query 'EventSourceMappings[].UUID' --output text 2>/dev/null || true)"
  for uuid in $MAPPINGS; do
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "DRY-RUN: would delete event source mapping $uuid"
    else
      if confirm "Delete DynamoDB stream event source mapping $uuid?"; then
        aws lambda delete-event-source-mapping --uuid "$uuid" --region "$AWS_REGION" >/dev/null
        info "Deleted event source mapping $uuid"
      else
        info "Skipped $uuid"
      fi
    fi
  done
else
  info "CloudWatch Lambda not found - nothing to do"
fi
# -------------------------------------------------------------------------------
# 2. Delete Lambda functions
# -------------------------------------------------------------------------------
log "Step 2 - Lambda functions"

for fn in "$HAA_PARSER_LAMBDA" "$HAA_CLOUDWATCH_LAMBDA"; do
  if aws lambda get-function --function-name "$fn" --region "$AWS_REGION" >/dev/null 2>&1; then
    OWNER="$(aws lambda get-function --function-name "$fn" --region "$AWS_REGION" --query 'Configuration.RevisionId' --output text 2>/dev/null || true)"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "DRY-RUN: would delete Lambda $fn"
    else
      if confirm "Delete Lambda function $fn?"; then
        aws lambda delete-function --function-name "$fn" --region "$AWS_REGION" >/dev/null
        info "Deleted Lambda $fn"
      else
        info "Skipped $fn"
      fi
    fi
  else
    info "Lambda $fn not found - nothing to do"
  fi
done

# -------------------------------------------------------------------------------
# 3. Clear S3 bucket notifications (HaaS parser only)
# -------------------------------------------------------------------------------
log "Step 3 - S3 bucket notifications"

if aws s3api head-bucket --bucket "$HAA_S3_BUCKET" --region "$AWS_REGION" >/dev/null 2>&1; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "DRY-RUN: would clear HaaS parser notifications on bucket $HAA_S3_BUCKET (other notifications preserved)"
  else
    if confirm "Clear HaaS parser S3 notifications on bucket $HAA_S3_BUCKET (other notifications preserved)?"; then
      NOTIF="$(aws s3api get-bucket-notification-configuration --bucket "$HAA_S3_BUCKET" --region "$AWS_REGION" 2>/dev/null || echo '{}')"
      MERGED="$(echo "$NOTIF" | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
cfg['LambdaFunctionConfigurations'] = []
print(json.dumps(cfg))
")"
      aws s3api put-bucket-notification-configuration --bucket "$HAA_S3_BUCKET" --notification-configuration "$MERGED" --region "$AWS_REGION" >/dev/null
      info "Cleared HaaS parser notifications"
    else
      info "Skipped notification cleanup"
    fi
  fi
else
  info "Bucket $HAA_S3_BUCKET not found - nothing to do"
fi
# -------------------------------------------------------------------------------
# 4. Detach IAM role policies and delete role
# -------------------------------------------------------------------------------
log "Step 4 - IAM role"

if aws iam get-role --role-name "$HAA_IAM_ROLE" >/dev/null 2>&1; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "DRY-RUN: would detach policies and delete IAM role $HAA_IAM_ROLE"
  else
    if confirm "Detach all policies and delete IAM role $HAA_IAM_ROLE?"; then
      for pol in $(aws iam list-attached-role-policies --role-name "$HAA_IAM_ROLE" --query '[*].PolicyArn' --output text 2>/dev/null || true); do
        aws iam detach-role-policy --role-name "$HAA_IAM_ROLE" --policy-arn "$pol" --region "$AWS_REGION" >/dev/null 2>&1 || true
      done
      for polname in $(aws iam list-role-policies --role-name "$HAA_IAM_ROLE" --query '[*].PolicyName' --output text 2>/dev/null || true); do
        aws iam delete-role-policy --role-name "$HAA_IAM_ROLE" --policy-name "$polname" --region "$AWS_REGION" >/dev/null 2>&1 || true
      done
      aws iam delete-role --role-name "$HAA_IAM_ROLE" --region "$AWS_REGION" >/dev/null
      info "Deleted IAM role $HAA_IAM_ROLE"
    else
      info "Skipped IAM role deletion"
    fi
  fi
else
  info "IAM role $HAA_IAM_ROLE not found - nothing to do"
fi

# -------------------------------------------------------------------------------
# 5. DynamoDB table (only with explicit --empty-bucket and confirmation)
# -------------------------------------------------------------------------------
log "Step 5 - DynamoDB table"

if aws dynamodb describe-table --table-name "$HAA_DYNAMODB_TABLE" --region "$AWS_REGION" >/dev/null 2>&1; then
  if [[ "$EMPTY_BUCKET" -eq 0 ]]; then
    info "DynamoDB table $HAA_DYNAMODB_TABLE NOT deleted (pass --empty-bucket to allow)"
  else
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "DRY-RUN: would delete DynamoDB table $HAA_DYNAMODB_TABLE"
    else
      if confirm "Permanently delete DynamoDB table $HAA_DYNAMODB_TABLE?"; then
        aws dynamodb delete-table --table-name "$HAA_DYNAMODB_TABLE" --region "$AWS_REGION" >/dev/null
        info "Deleted DynamoDB table $HAA_DYNAMODB_TABLE"
      else
        info "Skipped DynamoDB table deletion"
      fi
    fi
  fi
else
  info "DynamoDB table $HAA_DYNAMODB_TABLE not found - nothing to do"
fi

# -------------------------------------------------------------------------------
# 6. S3 bucket (NEVER automatic  requires --empty-bucket + explicit confirm)
# -------------------------------------------------------------------------------
log "Step 6 - S3 bucket"

if aws s3api head-bucket --bucket "$HAA_S3_BUCKET" --region "$AWS_REGION" >/dev/null 2>&1; then
  if [[ "$EMPTY_BUCKET" -eq 0 ]]; then
    info "S3 bucket $HAA_S3_BUCKET NOT deleted (data may be present; pass --empty-bucket to allow)"
  else
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "DRY-RUN: would delete S3 bucket $HAA_S3_BUCKET"
    else
      if confirm "Permanently delete S3 bucket $HAA_S3_BUCKET and ALL its contents?"; then
        aws s3api delete-bucket --bucket "$HAA_S3_BUCKET" --region "$AWS_REGION" >/dev/null
        info "Deleted S3 bucket $HAA_S3_BUCKET"
      else
        info "Skipped S3 bucket deletion"
      fi
    fi
  fi
else
  info "S3 bucket $HAA_S3_BUCKET not found - nothing to do"
fi

echo ""
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry-run complete. Re-run with --confirm to execute (interactive)."
else
  echo "Teardown complete."
fi
