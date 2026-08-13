#!/usr/bin/env bash
# Set or rotate the Anthropic API key on the deployed Lambda, without touching
# anything else. Run in the same CloudShell session as deploy.sh, after deploy.sh
# has run at least once.
#
# Usage:
#   ANTHROPIC_API_KEY=sk-ant-api03-xxxx bash set-api-key.sh

set -euo pipefail

REGION="ap-southeast-2"
FUNCTION_NAME="wb-scheduler-api"
S3_BUCKET="wbmedia-assets-967307909838-ap-southeast-2-an"
S3_KEY="scheduler/clients.json"
ALLOWED_ORIGIN="https://wbmedia-au.github.io"

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ERROR: set ANTHROPIC_API_KEY first, e.g.:" >&2
  echo "  ANTHROPIC_API_KEY=sk-ant-api03-xxxx bash set-api-key.sh" >&2
  exit 1
fi

aws lambda update-function-configuration \
  --function-name "$FUNCTION_NAME" \
  --environment "Variables={S3_BUCKET=${S3_BUCKET},S3_KEY=${S3_KEY},ALLOWED_ORIGIN=${ALLOWED_ORIGIN},ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}}" \
  --region "$REGION" >/dev/null

aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$REGION"
echo "ANTHROPIC_API_KEY updated on $FUNCTION_NAME."
