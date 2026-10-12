#!/bin/bash
set -e
# Safety guard: this script must only provision LocalStack resources.
# It uses `awslocal` and must NEVER talk to real AWS. If AWS_MODE=real is
# set in the environment, refuse to run - real-AWS provisioning is handled
# by ./scripts/deploy_aws.sh instead.
AWS_MODE="${AWS_MODE:-local}"
if [[ "$AWS_MODE" == "real" ]]; then
  echo "ERROR: 01_setup.sh is a LocalStack-only init script."
  echo "For real AWS use: AWS_MODE=real ./scripts/deploy_aws.sh"
  exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   HaaS — Provisioning AWS infrastructure         ║"
echo "║   Mode: LocalStack (mock)                         ║"
echo "╚══════════════════════════════════════════════════╝"

REGION="us-east-1"
ACCOUNT_ID="000000000000"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/lambda-exec-role"

# ── 1. S3 bucket ──────────────────────────────────────
echo "[1/5] Creating S3 bucket: honeypot-logs-2025"
if awslocal s3api head-bucket --bucket honeypot-logs-2025 >/dev/null 2>&1; then
  echo "      Bucket already exists - keeping existing bucket"
else
  awslocal s3 mb s3://honeypot-logs-2025 --region "$REGION"
  echo "      Bucket created"
fi

# ── 2. DynamoDB table with streams ────────────────────
echo "[2/5] Creating DynamoDB table: CowrieLogs"
awslocal dynamodb create-table \
  --table-name CowrieLogs \
  --attribute-definitions \
    AttributeName=session,AttributeType=S \
    AttributeName=timestamp,AttributeType=S \
  --key-schema \
    AttributeName=session,KeyType=HASH \
    AttributeName=timestamp,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES \
  --region "$REGION"

# ── 3. IAM role ───────────────────────────────────────
echo "[3/5] Creating IAM role"
awslocal iam create-role \
  --role-name lambda-exec-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' 2>/dev/null || true

# ── 4. Deploy CowrieLogParser + S3 trigger ────────────
echo "[4/5] Deploying CowrieLogParser Lambda"
cd /tmp
cp /opt/lambda-src/CowrieLogParser.py .
zip -q CowrieLogParser.zip CowrieLogParser.py

awslocal lambda create-function \
  --function-name CowrieLogParser \
  --runtime python3.11 \
  --role "$ROLE_ARN" \
  --handler CowrieLogParser.lambda_handler \
  --zip-file fileb:///tmp/CowrieLogParser.zip \
  --timeout 30 \
  --region "$REGION"

echo "      Waiting for CowrieLogParser to become Active..."
awslocal lambda wait function-active \
  --function-name CowrieLogParser \
  --region "$REGION"

PARSER_ARN=$(awslocal lambda get-function \
  --function-name CowrieLogParser \
  --query 'Configuration.FunctionArn' \
  --output text --region "$REGION")

awslocal lambda add-permission \
  --function-name CowrieLogParser \
  --statement-id s3-invoke \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn arn:aws:s3:::honeypot-logs-2025 \
  --region "$REGION"

awslocal s3api put-bucket-notification-configuration \
  --bucket honeypot-logs-2025 \
  --notification-configuration "{
    \"LambdaFunctionConfigurations\": [{
      \"LambdaFunctionArn\": \"${PARSER_ARN}\",
      \"Events\": [\"s3:ObjectCreated:*\"],
      \"Filter\": {\"Key\": {\"FilterRules\": [{\"Name\": \"suffix\",\"Value\": \".log\"}]}}
    }]
  }"

echo "      S3 trigger configured"

# ── 5. Deploy LogDynamoDBToCloudWatch + stream trigger ─
echo "[5/5] Deploying LogDynamoDBToCloudWatch Lambda"
cd /tmp
cp /opt/lambda-src/LogDynamoDBToCloudWatch.py .
zip -q LogDynamoDBToCloudWatch.zip LogDynamoDBToCloudWatch.py

awslocal lambda create-function \
  --function-name LogDynamoDBToCloudWatch \
  --runtime python3.11 \
  --role "$ROLE_ARN" \
  --handler LogDynamoDBToCloudWatch.lambda_handler \
  --zip-file fileb:///tmp/LogDynamoDBToCloudWatch.zip \
  --timeout 30 \
  --region "$REGION"

awslocal lambda wait function-active \
  --function-name LogDynamoDBToCloudWatch \
  --region "$REGION"

STREAM_ARN=$(awslocal dynamodb describe-table \
  --table-name CowrieLogs \
  --query 'Table.LatestStreamArn' \
  --output text --region "$REGION")

awslocal lambda create-event-source-mapping \
  --function-name LogDynamoDBToCloudWatch \
  --event-source-arn "$STREAM_ARN" \
  --starting-position LATEST \
  --batch-size 10 \
  --region "$REGION"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Infrastructure ready                            ║"
echo "║   S3 → Lambda → DynamoDB → Lambda pipeline live  ║"
echo "╚══════════════════════════════════════════════════╝"
