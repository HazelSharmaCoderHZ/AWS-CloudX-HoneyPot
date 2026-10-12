#!/bin/bash
# common.sh — Shared configuration for the HaaS pipeline (both local & real AWS).
#
# Sourced by deploy_aws.sh, validate_aws.sh, and teardown_aws.sh.
# Defaults preserve the existing LocalStack behaviour (AWS_MODE=local).
#
# Override any value with environment variables, e.g.:
#   AWS_MODE=real AWS_REGION=eu-west-1 ./scripts/deploy_aws.sh

# ── Mode ────────────────────────────────────────────────────────────────────
# local  → LocalStack (docker compose up). Default. Uses awslocal.
# real   → Real AWS account. Uses the aws CLI + standard credential chain.
export AWS_MODE="${AWS_MODE:-local}"

# ── Region (real AWS only; ignored by LocalStack) ───────────────────────────
export AWS_REGION="${AWS_REGION:-us-east-1}"

# ── Resource names — kept identical across local & real modes ────────────────
export HAA_S3_BUCKET="honeypot-logs-2025"
export HAA_DYNAMODB_TABLE="CowrieLogs"
export HAA_IAM_ROLE="lambda-exec-role"
export HAA_PARSER_LAMBDA="CowrieLogParser"
export HAA_CLOUDWATCH_LAMBDA="LogDynamoDBToCloudWatch"

# ── Lambda runtime configuration ────────────────────────────────────────────
export HAA_LAMBDA_RUNTIME="python3.11"
export HAA_LAMBDA_TIMEOUT=30
export HAA_LAMBDA_BATCH_SIZE=10

# ── Derived paths ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HAA_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Directory containing CowrieLogParser.py / LogDynamoDBToCloudWatch.py
export HAA_LAMBDA_SRC_DIR="${HAA_LAMBDA_SRC_DIR:-$HAA_REPO_ROOT/Lambda Functions}"