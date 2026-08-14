#!/usr/bin/env bash
# WB Media Scheduler — backend deploy script
#
# Run this in AWS CloudShell (console.aws.amazon.com -> CloudShell icon) while
# logged into account 967307909838. Uses your already-authenticated console
# session, so no local AWS CLI setup or credentials needed.
#
# Usage:
#   1. Upload lambda_function.py into CloudShell (drag-and-drop, or Actions -> Upload file)
#      into the same directory as this script.
#   2. (Optional) export ANTHROPIC_API_KEY=sk-ant-... before running, if you have it ready.
#   3. bash deploy.sh
#
# Safe to re-run: it updates existing resources instead of failing on them.

set -euo pipefail

REGION="ap-southeast-2"
ACCOUNT_ID="967307909838"
S3_BUCKET="wbmedia-assets-967307909838-ap-southeast-2-an"
S3_KEY="scheduler/clients.json"
ALLOWED_ORIGIN="https://wbmedia-au.github.io"

FUNCTION_NAME="wb-scheduler-api"
ROLE_NAME="wb-scheduler-lambda-role"
API_NAME="wb-scheduler-api"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f lambda_function.py ]; then
  echo "ERROR: lambda_function.py not found in $SCRIPT_DIR. Upload it first." >&2
  exit 1
fi

echo "== Packaging Lambda code =="
rm -f function.zip
zip -q function.zip lambda_function.py
echo "Packaged function.zip"

echo "== IAM role =="
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "Role $ROLE_NAME already exists, reusing."
else
  cat > /tmp/trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document file:///tmp/trust-policy.json \
    --region "$REGION" >/dev/null
  echo "Created role $ROLE_NAME"
fi

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null

# Superseded by the combined "wb-scheduler-s3-access" policy below — remove if present
# from an earlier deploy so there's a single source of truth for S3 permissions.
aws iam delete-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "wb-scheduler-clients-json-access" >/dev/null 2>&1 || true

cat > /tmp/s3-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::${S3_BUCKET}/${S3_KEY}"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${S3_BUCKET}/scheduler/uploads/*"
    }
  ]
}
EOF
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "wb-scheduler-s3-access" \
  --policy-document file:///tmp/s3-policy.json >/dev/null
echo "Attached S3 policy: read/write on ${S3_KEY}, read/write/delete on scheduler/uploads/*"

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

echo "== S3 bucket CORS (allow browser PUT uploads) =="
EXISTING_CORS=$(aws s3api get-bucket-cors --bucket "$S3_BUCKET" --region "$REGION" 2>/dev/null || echo '{"CORSRules":[]}')
echo "$EXISTING_CORS" > /tmp/existing-cors.json
python3 - <<PYEOF
import json

with open("/tmp/existing-cors.json") as f:
    existing = json.load(f)

rules = existing.get("CORSRules", [])
new_rule = {
    "AllowedOrigins": ["${ALLOWED_ORIGIN}"],
    "AllowedMethods": ["PUT"],
    "AllowedHeaders": ["*"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3000,
}
# Replace any prior rule with the same origin+methods instead of duplicating it on re-run.
rules = [
    r for r in rules
    if not (r.get("AllowedOrigins") == new_rule["AllowedOrigins"] and r.get("AllowedMethods") == new_rule["AllowedMethods"])
]
rules.append(new_rule)

with open("/tmp/cors.json", "w") as f:
    json.dump({"CORSRules": rules}, f)
PYEOF
aws s3api put-bucket-cors --bucket "$S3_BUCKET" --cors-configuration file:///tmp/cors.json --region "$REGION"
echo "Bucket CORS updated (existing rules preserved, PUT from ${ALLOWED_ORIGIN} added)."

echo "== Lambda function =="
ENV_VARS="Variables={S3_BUCKET=${S3_BUCKET},S3_KEY=${S3_KEY},ALLOWED_ORIGIN=${ALLOWED_ORIGIN},ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}}"

if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "Function exists, updating code + config..."
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file fileb://function.zip \
    --region "$REGION" >/dev/null
  aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$REGION"
  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --timeout 60 \
    --memory-size 512 \
    --environment "$ENV_VARS" \
    --region "$REGION" >/dev/null
  aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$REGION"
else
  echo "Creating function (waiting for IAM role to propagate)..."
  # New IAM roles can take a few seconds to become assumable.
  for i in 1 2 3 4 5 6; do
    if aws lambda create-function \
      --function-name "$FUNCTION_NAME" \
      --runtime python3.12 \
      --role "$ROLE_ARN" \
      --handler lambda_function.lambda_handler \
      --timeout 60 \
      --memory-size 512 \
      --zip-file fileb://function.zip \
      --environment "$ENV_VARS" \
      --region "$REGION" >/dev/null 2>/tmp/create-fn-err.log; then
      break
    fi
    echo "  ...role not ready yet, retrying in 5s ($i/6)"
    sleep 5
    if [ "$i" -eq 6 ]; then
      cat /tmp/create-fn-err.log >&2
      exit 1
    fi
  done
  aws lambda wait function-active --function-name "$FUNCTION_NAME" --region "$REGION"
fi
echo "Lambda function $FUNCTION_NAME ready (60s timeout)."

FUNCTION_ARN=$(aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" --query 'Configuration.FunctionArn' --output text)

echo "== HTTP API (API Gateway v2) =="
CORS_CONFIG=$(cat <<EOF
{
  "AllowOrigins": ["${ALLOWED_ORIGIN}"],
  "AllowMethods": ["GET", "PUT", "POST", "OPTIONS"],
  "AllowHeaders": ["content-type"]
}
EOF
)

API_ID=$(aws apigatewayv2 get-apis --region "$REGION" --query "Items[?Name=='${API_NAME}'].ApiId" --output text)

if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
  echo "API $API_NAME exists (ApiId=$API_ID), updating CORS..."
  aws apigatewayv2 update-api \
    --api-id "$API_ID" \
    --cors-configuration "$CORS_CONFIG" \
    --region "$REGION" >/dev/null
else
  API_ID=$(aws apigatewayv2 create-api \
    --name "$API_NAME" \
    --protocol-type HTTP \
    --cors-configuration "$CORS_CONFIG" \
    --region "$REGION" \
    --query 'ApiId' --output text)
  echo "Created API (ApiId=$API_ID)"
fi

INTEGRATION_ID=$(aws apigatewayv2 get-integrations --api-id "$API_ID" --region "$REGION" \
  --query "Items[?IntegrationUri=='${FUNCTION_ARN}'].IntegrationId" --output text)

if [ -z "$INTEGRATION_ID" ] || [ "$INTEGRATION_ID" == "None" ]; then
  # 30000ms is the hard ceiling for HTTP API integration timeouts — API Gateway cannot
  # go higher than this no matter what the Lambda function's own timeout is set to.
  INTEGRATION_ID=$(aws apigatewayv2 create-integration \
    --api-id "$API_ID" \
    --integration-type AWS_PROXY \
    --integration-uri "$FUNCTION_ARN" \
    --payload-format-version "2.0" \
    --timeout-in-millis 30000 \
    --region "$REGION" \
    --query 'IntegrationId' --output text)
  echo "Created integration (IntegrationId=$INTEGRATION_ID)"
else
  aws apigatewayv2 update-integration \
    --api-id "$API_ID" \
    --integration-id "$INTEGRATION_ID" \
    --timeout-in-millis 30000 \
    --region "$REGION" >/dev/null
  echo "Reusing integration $INTEGRATION_ID (timeout raised to API Gateway's 30000ms ceiling)"
fi

for ROUTE in "GET /clients" "PUT /clients" "POST /extract-pdf" "POST /get-upload-url"; do
  EXISTING=$(aws apigatewayv2 get-routes --api-id "$API_ID" --region "$REGION" \
    --query "Items[?RouteKey=='${ROUTE}'].RouteId" --output text)
  if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
    echo "Route '$ROUTE' already exists, skipping."
  else
    aws apigatewayv2 create-route \
      --api-id "$API_ID" \
      --route-key "$ROUTE" \
      --target "integrations/$INTEGRATION_ID" \
      --region "$REGION" >/dev/null
    echo "Created route: $ROUTE"
  fi
done

# /extract-from-s3 has moved off API Gateway onto a Lambda Function URL (see below) to
# get around API Gateway's hard 30s integration timeout. Remove the old route if a
# previous deploy created it, so there's exactly one place this endpoint is reachable.
OLD_ROUTE_ID=$(aws apigatewayv2 get-routes --api-id "$API_ID" --region "$REGION" \
  --query "Items[?RouteKey=='POST /extract-from-s3'].RouteId" --output text)
if [ -n "$OLD_ROUTE_ID" ] && [ "$OLD_ROUTE_ID" != "None" ]; then
  aws apigatewayv2 delete-route --api-id "$API_ID" --route-id "$OLD_ROUTE_ID" --region "$REGION" >/dev/null
  echo "Removed old API Gateway route POST /extract-from-s3 (moved to Function URL)"
fi

if aws apigatewayv2 get-stage --api-id "$API_ID" --stage-name '$default' --region "$REGION" >/dev/null 2>&1; then
  echo "Default stage already exists."
else
  aws apigatewayv2 create-stage \
    --api-id "$API_ID" \
    --stage-name '$default' \
    --auto-deploy \
    --region "$REGION" >/dev/null
  echo "Created \$default stage (auto-deploy on)."
fi

echo "== Lambda permission for API Gateway =="
aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id "apigw-invoke-${API_ID}" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*" \
  --region "$REGION" >/dev/null 2>&1 || echo "(permission already exists, skipping)"

API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com"

echo "== Lambda Function URL (POST /extract-from-s3, no 30s API Gateway ceiling) =="
FUNCTION_URL_CORS=$(cat <<EOF
{
  "AllowOrigins": ["${ALLOWED_ORIGIN}"],
  "AllowMethods": ["POST"],
  "AllowHeaders": ["content-type"]
}
EOF
)

if aws lambda get-function-url-config --function-name "$FUNCTION_NAME" --region "$REGION" >/dev/null 2>&1; then
  aws lambda update-function-url-config \
    --function-name "$FUNCTION_NAME" \
    --auth-type NONE \
    --cors "$FUNCTION_URL_CORS" \
    --region "$REGION" >/dev/null
  echo "Function URL config updated."
else
  aws lambda create-function-url-config \
    --function-name "$FUNCTION_NAME" \
    --auth-type NONE \
    --cors "$FUNCTION_URL_CORS" \
    --region "$REGION" >/dev/null
  echo "Function URL config created."
fi

# Resource policy allowing public, unauthenticated invocation via the Function URL —
# separate from the lambda:InvokeFunction permission API Gateway uses above. This makes
# the extraction endpoint reachable the same way the API Gateway endpoints already are
# (no auth on any of them), just via a different URL with no 30s ceiling.
aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id "FunctionURLAllowPublicAccess" \
  --action lambda:InvokeFunctionUrl \
  --principal '*' \
  --function-url-auth-type NONE \
  --region "$REGION" >/dev/null 2>&1 || echo "(Function URL invoke permission already exists, skipping)"

FUNCTION_URL=$(aws lambda get-function-url-config --function-name "$FUNCTION_NAME" --region "$REGION" --query 'FunctionUrl' --output text)
# Trim the trailing slash AWS includes, so it matches the no-trailing-slash convention
# used for the API Gateway base URL elsewhere in this app.
FUNCTION_URL="${FUNCTION_URL%/}"

echo ""
echo "================================================================"
echo " Deployment complete."
echo ""
echo " API Gateway base URL (clients + get-upload-url):"
echo "   $API_URL"
echo ""
echo " Lambda Function URL (PDF extraction, no timeout ceiling):"
echo "   $FUNCTION_URL"
echo ""
echo " Paste BOTH into the Scheduler tool's Settings tab."
echo "================================================================"
echo ""

if [ -z "$ANTHROPIC_API_KEY" ]; then
  echo "NOTE: ANTHROPIC_API_KEY was not set on this run — if it's not already set from a"
  echo "previous deploy, PDF extraction will fail until you run:"
  echo "  ANTHROPIC_API_KEY=sk-ant-... bash set-api-key.sh"
  echo ""
fi

echo "== Smoke test: GET /clients (API Gateway) =="
curl -s "${API_URL}/clients"
echo ""
echo "== Smoke test: POST /get-upload-url (API Gateway) =="
curl -s -X POST "${API_URL}/get-upload-url"
echo ""
echo "== Smoke test: POST /extract-from-s3 with a bogus key (Function URL, expect a clean 400) =="
curl -s -X POST "${FUNCTION_URL}/extract-from-s3" -H "Content-Type: application/json" -d '{"s3Key":"bogus"}'
echo ""
