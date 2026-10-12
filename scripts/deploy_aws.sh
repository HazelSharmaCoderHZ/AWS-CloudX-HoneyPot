#!/bin/bash
# deploy_aws.sh  Idempotent real-AWS provisioning for the HaaS pipeline.
#
# Creates (or updates) only:
#   - S3 bucket: honeypot-logs-2025
#   - DynamoDB table: CowrieLogs (with streams)
#   - IAM role: lambda-exec-role (with execution policies)
#   - Lambda: CowrieLogParser + S3 trigger
#   - Lambda: LogDynamoDBToCloudWatch + DynamoDB stream trigger
#
# Reuses the existing Lambda source in "Lambda Functions/" and the existing
# table schema / trigger / IAM configuration. Nothing is deployed unless
# AWS_MODE=real and validation passes.
#
# Usage:
#   AWS_MODE=real ./scripts/validate_aws.sh        # read-only checks first
#   AWS_MODE=real ./scripts/deploy_aws.sh          # deploy
#   AWS_MODE=real ./scripts/deploy_aws.sh --dry-run  # plan only
#
# Credentials come from the standard AWS CLI chain only. Never set keys here.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "Unknown argument: $1"; exit 2 ;;
  esac
done

if [[ "$AWS_MODE" != "real" ]]; then
  echo "ERROR: deploy_aws.sh requires AWS_MODE=real (got '$AWS_MODE')."
  echo "LocalStack mode is handled by: docker compose up"
  exit 1
fi

AWS="$(command -v aws)"
if [[ -z "$AWS" ]]; then
  echo "ERROR: 'aws' CLI not found on PATH."
  exit 1
fi

log()  { echo "[deploy] $*"; }
run()  { if [[ "$DRY_RUN" -eq 1 ]]; then echo "DRY-RUN: $*"; else log "$*"; "$@"; fi; }
info() { echo "  $*"; }
warn() { echo "  WARN: $*"; }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [[ -z "$ACCOUNT_ID" ]]; then
  echo "ERROR: cannot determine AWS account id (sts get-caller-identity failed)."
  exit 1
fi
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${HAA_IAM_ROLE}"
PARSER_ARN=""
CW_ARN=""

echo "+----------------------------------------------------------+"
echo "¦   HaaS  Real AWS deployment                           ¦"
echo "¦   Account: $ACCOUNT_ID  Region: $AWS_REGION            ¦"
echo "+----------------------------------------------------------+"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  *** DRY-RUN MODE  no resources will be created ***"
fi
# -------------------------------------------------------------------------------
# 1. S3 bucket
# -------------------------------------------------------------------------------
log "Step 1/5 - S3 bucket: ${HAA_S3_BUCKET}"

if aws s3api head-bucket --bucket "$HAA_S3_BUCKET" --region "$AWS_REGION" >/dev/null 2>&1; then
  OWNER="$(aws s3api head-bucket --bucket "$HAA_S3_BUCKET" --region "$AWS_REGION" --query Owner.ID --output text 2>/dev/null || true)"
  if [[ "$OWNER" == "$ACCOUNT_ID" ]]; then
    info "Bucket already exists and is owned by this account - keeping existing bucket"
  else
    echo "ERROR: Bucket $HAA_S3_BUCKET exists but is owned by account $OWNER, not $ACCOUNT_ID. Aborting to avoid clobbering foreign data."
    exit 1
  fi
else
  run aws s3api create-bucket --bucket "$HAA_S3_BUCKET" --region "$AWS_REGION" --create-bucket-configuration LocationConstraint="$AWS_REGION"
  info "Bucket created"
fi
# -------------------------------------------------------------------------------
# 2. DynamoDB table with streams
# -------------------------------------------------------------------------------
log "Step 2/5 - DynamoDB table: ${HAA_DYNAMODB_TABLE}"

if aws dynamodb describe-table --table-name "$HAA_DYNAMODB_TABLE" --region "$AWS_REGION" >/dev/null 2>&1; then
  SCHEMA_OK="$(aws dynamodb describe-table --table-name "$HAA_DYNAMODB_TABLE" --region "$AWS_REGION" --query "TableStatus=='Active' && AttributeDefinitions[?AttributeName=='session'].AttributeType=='S' && AttributeDefinitions[?AttributeName=='timestamp'].AttributeType=='S' && KeySchema[?AttributeName=='session'].KeyType=='HASH' && KeySchema[?AttributeName=='timestamp'].KeyType=='RANGE'" --output text 2>/dev/null || echo False)"
  if [[ "$SCHEMA_OK" == "True" ]]; then
    info "Table already exists with matching schema - keeping existing table"
  else
    echo "ERROR: Table $HAA_DYNAMODB_TABLE exists but schema does not match. Aborting."
    exit 1
  fi
  STREAM_ARN="$(aws dynamodb describe-table --table-name "$HAA_DYNAMODB_TABLE" --region "$AWS_REGION" --query 'Table.LatestStreamArn' --output text 2>/dev/null || true)"
  if [[ -z "$STREAM_ARN" ]]; then
    warn "Table exists but has no stream - enabling streams"
    aws dynamodb update-table --table-name "$HAA_DYNAMODB_TABLE" --region "$AWS_REGION" --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES >/dev/null
    aws dynamodb wait table-active --table-name "$HAA_DYNAMODB_TABLE" --region "$AWS_REGION"
    STREAM_ARN="$(aws dynamodb describe-table --table-name "$HAA_DYNAMODB_TABLE" --region "$AWS_REGION" --query 'Table.LatestStreamArn' --output text)"
    info "Streams enabled: $STREAM_ARN"
  else
    info "Streams already enabled: $STREAM_ARN"
  fi
else
  run aws dynamodb create-table --table-name "$HAA_DYNAMODB_TABLE" \
    --attribute-definitions AttributeName=session,AttributeType=S AttributeName=timestamp,AttributeType=S \
    --key-schema AttributeName=session,KeyType=HASH AttributeName=timestamp,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
    --region "$AWS_REGION"
  info "Table created"
  aws dynamodb wait table-active --table-name "$HAA_DYNAMODB_TABLE" --region "$AWS_REGION"
  STREAM_ARN="$(aws dynamodb describe-table --table-name "$HAA_DYNAMODB_TABLE" --region "$AWS_REGION" --query 'Table.LatestStreamArn' --output text)"
  info "Stream ARN: $STREAM_ARN"
fi
# -------------------------------------------------------------------------------
# 3. IAM role with execution policies
# -------------------------------------------------------------------------------
log "Step 3/5 - IAM role: ${HAA_IAM_ROLE}"

if aws iam get-role --role-name "$HAA_IAM_ROLE" >/dev/null 2>&1; then
  info "Role already exists - verifying policies"
  EXISTING="$(aws iam list-attached-role-policies --role-name "$HAA_IAM_ROLE" --query '[*].PolicyName' --output text 2>/dev/null || true)"
  info "Attached managed policies: $EXISTING"
else
  run aws iam create-role --role-name "$HAA_IAM_ROLE" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' --region "$AWS_REGION"
  info "Role created"
fi

attach_policy() {
  local arn="$1"
  if aws iam list-attached-role-policies --role-name "$HAA_IAM_ROLE" --query "AttachedPolicies[?PolicyArn=='$arn'].PolicyArn" --output text 2>/dev/null | grep -q "$arn"; then
    info "Policy already attached: $arn"
  else
    run aws iam attach-role-policy --role-name "$HAA_IAM_ROLE" --policy-arn "$arn" --region "$AWS_REGION"
    info "Attached policy: $arn"
  fi
}
attach_policy "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
attach_policy "arn:aws:iam::aws:policy/AWSLambdaExecute"

STREAM_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["dynamodb:GetRecords","dynamodb:GetShardIterator","dynamodb:DescribeStream","dynamodb:ListStreams"],"Resource":"*"}]}'
if aws iam get-role-policy --role-name "$HAA_IAM_ROLE" --policy-name "HaaDynamoDBStreamRead" >/dev/null 2>&1; then
  info "Inline policy HaaDynamoDBStreamRead already present"
else
  run aws iam put-role-policy --role-name "$HAA_IAM_ROLE" --policy-name "HaaDynamoDBStreamRead" --policy-document "$STREAM_POLICY" --region "$AWS_REGION"
  info "Attached inline policy: HaaDynamoDBStreamRead"
fi

PARSER_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject"],"Resource":"arn:aws:s3:::BUCKET_PLACEHOLDER/*"},{"Effect":"Allow","Action":["dynamodb:PutItem","dynamodb:BatchWriteItem","dynamodb:DescribeTable"],"Resource":"arn:aws:dynamodb:*:*:table/TABLE_PLACEHOLDER"}]}'
PARSER_POLICY="${PARSER_POLICY//BUCKET_PLACEHOLDER/$HAA_S3_BUCKET}"
PARSER_POLICY="${PARSER_POLICY//TABLE_PLACEHOLDER/$HAA_DYNAMODB_TABLE}"
if aws iam get-role-policy --role-name "$HAA_IAM_ROLE" --policy-name "HaaParserInvoke" >/dev/null 2>&1; then
  info "Inline policy HaaParserInvoke already present"
else
  run aws iam put-role-policy --role-name "$HAA_IAM_ROLE" --policy-name "HaaParserInvoke" --policy-document "$PARSER_POLICY" --region "$AWS_REGION"
  info "Attached inline policy: HaaParserInvoke"
fi
# -------------------------------------------------------------------------------
# 4. CowrieLogParser Lambda + S3 trigger
# -------------------------------------------------------------------------------
log "Step 4/5 - Lambda: ${HAA_PARSER_LAMBDA}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
cp "$HAA_LAMBDA_SRC_DIR/CowrieLogParser.py" "$TMPDIR/"
(cd "$TMPDIR" && zip -q CowrieLogParser.zip CowrieLogParser.py)
ZIPFILE="fileb://$TMPDIR/CowrieLogParser.zip"

if aws lambda get-function --function-name "$HAA_PARSER_LAMBDA" --region "$AWS_REGION" >/dev/null 2>&1; then
  info "Lambda already exists - updating code and config"
  aws lambda update-function-code --function-name "$HAA_PARSER_LAMBDA" --zip-file "$ZIPFILE" --region "$AWS_REGION" >/dev/null
  aws lambda update-function-configuration --function-name "$HAA_PARSER_LAMBDA" --timeout "$HAA_LAMBDA_TIMEOUT" --runtime "$HAA_LAMBDA_RUNTIME" --region "$AWS_REGION" >/dev/null
  aws lambda wait function-active --function-name "$HAA_PARSER_LAMBDA" --region "$AWS_REGION"
  info "Lambda updated"
else
  run aws lambda create-function --function-name "$HAA_PARSER_LAMBDA" --runtime "$HAA_LAMBDA_RUNTIME" --role "$ROLE_ARN" --handler "CowrieLogParser.lambda_handler" --zip-file "$ZIPFILE" --timeout "$HAA_LAMBDA_TIMEOUT" --region "$AWS_REGION"
  info "Lambda created"
  aws lambda wait function-active --function-name "$HAA_PARSER_LAMBDA" --region "$AWS_REGION"
fi
PARSER_ARN="$(aws lambda get-function --function-name "$HAA_PARSER_LAMBDA" --region "$AWS_REGION" --query 'Configuration.FunctionArn' --output text)"
info "Parser ARN: $PARSER_ARN"

if aws lambda get-policy --function-name "$HAA_PARSER_LAMBDA" --region "$AWS_REGION" --statement-id "s3-invoke" >/dev/null 2>&1; then
  info "S3 invoke permission already present"
else
  run aws lambda add-permission --function-name "$HAA_PARSER_LAMBDA" --statement-id "s3-invoke" --action "lambda:InvokeFunction" --principal "s3.amazonaws.com" --source-arn "arn:aws:s3:::${HAA_S3_BUCKET}" --region "$AWS_REGION"
  info "S3 invoke permission granted"
fi

# S3 notification - merge parser config, preserving any pre-existing notifications
EXISTING_NOTIF="$(aws s3api get-bucket-notification-configuration --bucket "$HAA_S3_BUCKET" --region "$AWS_REGION" 2>/dev/null || echo '{}')"
MERGED="$(echo "$EXISTING_NOTIF" | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
lcs = [n for n in cfg.get('LambdaFunctionConfigurations', []) if n.get('LambdaFunctionArn') != '$PARSER_ARN']
lcs.append({'LambdaFunctionArn': '$PARSER_ARN', 'Events': ['s3:ObjectCreated:*'], 'Filter': {'Key': {'FilterRules': [{'Name': 'suffix', 'Value': '.log'}]}}})
cfg['LambdaFunctionConfigurations'] = lcs
print(json.dumps(cfg))
")"
run aws s3api put-bucket-notification-configuration --bucket "$HAA_S3_BUCKET" --notification-configuration "$MERGED" --region "$AWS_REGION"
info "S3 notification configured (CowrieLogParser triggered on .log files; other notifications preserved)"
# -------------------------------------------------------------------------------
# 5. LogDynamoDBToCloudWatch Lambda + DynamoDB stream trigger
# -------------------------------------------------------------------------------
log "Step 5/5 - Lambda: ${HAA_CLOUDWATCH_LAMBDA}"

TMPDIR2="$(mktemp -d)"
trap 'rm -rf "$TMPDIR" "$TMPDIR2"' EXIT
cp "$HAA_LAMBDA_SRC_DIR/LogDynamoDBToCloudWatch.py" "$TMPDIR2/"
(cd "$TMPDIR2" && zip -q LogDynamoDBToCloudWatch.zip LogDynamoDBToCloudWatch.py)
ZIPFILE2="fileb://$TMPDIR2/LogDynamoDBToCloudWatch.zip"

if aws lambda get-function --function-name "$HAA_CLOUDWATCH_LAMBDA" --region "$AWS_REGION" >/dev/null 2>&1; then
  info "Lambda already exists - updating code and config"
  aws lambda update-function-code --function-name "$HAA_CLOUDWATCH_LAMBDA" --zip-file "$ZIPFILE2" --region "$AWS_REGION" >/dev/null
  aws lambda update-function-configuration --function-name "$HAA_CLOUDWATCH_LAMBDA" --timeout "$HAA_LAMBDA_TIMEOUT" --runtime "$HAA_LAMBDA_RUNTIME" --region "$AWS_REGION" >/dev/null
  aws lambda wait function-active --function-name "$HAA_CLOUDWATCH_LAMBDA" --region "$AWS_REGION"
  info "Lambda updated"
else
  run aws lambda create-function --function-name "$HAA_CLOUDWATCH_LAMBDA" --runtime "$HAA_LAMBDA_RUNTIME" --role "$ROLE_ARN" --handler "LogDynamoDBToCloudWatch.lambda_handler" --zip-file "$ZIPFILE2" --timeout "$HAA_LAMBDA_TIMEOUT" --region "$AWS_REGION"
  info "Lambda created"
  aws lambda wait function-active --function-name "$HAA_CLOUDWATCH_LAMBDA" --region "$AWS_REGION"
fi
CW_ARN="$(aws lambda get-function --function-name "$HAA_CLOUDWATCH_LAMBDA" --region "$AWS_REGION" --query 'Configuration.FunctionArn' --output text)"
info "CloudWatch Lambda ARN: $CW_ARN"

# DynamoDB stream event source mapping (idempotent)
if aws lambda list-event-source-mappings --function-name "$HAA_CLOUDWATCH_LAMBDA" --region "$AWS_REGION" --query 'EventSourceMappings[?EventSourceArn=='"$STREAM_ARN"'].UUID' --output text 2>/dev/null | grep -q .; then
  info "DynamoDB stream event source mapping already present"
else
  run aws lambda create-event-source-mapping --function-name "$HAA_CLOUDWATCH_LAMBDA" --event-source-arn "$STREAM_ARN" --starting-position LATEST --batch-size "$HAA_LAMBDA_BATCH_SIZE" --region "$AWS_REGION"
  info "DynamoDB stream event source mapping created"
fi

echo ""
echo "+----------------------------------------------------------+"
echo "¦   Real AWS deployment complete                          ¦"
echo "¦   S3 -> Lambda -> DynamoDB -> Lambda pipeline live      ¦"
echo "+----------------------------------------------------------+"
