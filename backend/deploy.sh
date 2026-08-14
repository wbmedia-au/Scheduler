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
#   2. bash deploy.sh sk-ant-api03-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#      (pass your Anthropic API key as the first argument; omit it only if you've already
#      set it on the function on a previous run and just want to redeploy code/infra)
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
ANTHROPIC_API_KEY="${1:-${ANTHROPIC_API_KEY:-}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f lambda_function.py ]; then
  echo "ERROR: lambda_function.py not found in $SCRIPT_DIR. Upload it first." >&2
  exit 1
fi

echo "== Packaging Lambda code (with pypdf) =="
rm -rf build function.zip
mkdir -p build
# pypdf is pure Python (no compiled extensions, no hard dependencies), so installing it
# with whatever python3/pip3 CloudShell provides and zipping it up is safe to run on the
# Lambda python3.12 runtime regardless of CloudShell's own Python version.
pip3 install --quiet --target build pypdf
cp lambda_function.py build/
(cd build && zip -qr ../function.zip .)
echo "Packaged function.zip ($(du -h function.zip | cut -f1))"

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
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::${S3_BUCKET}/scheduler/jobs/*"
    }
  ]
}
EOF
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "wb-scheduler-s3-access" \
  --policy-document file:///tmp/s3-policy.json >/dev/null
echo "Attached S3 policy: clients.json, scheduler/uploads/*, scheduler/jobs/*"

# The Lambda's own execution role needs permission to invoke the function itself
# (InvocationType='Event') for the async extraction job. This is an identity-based
# policy on the role, unrelated to the resource-based invoke permissions API Gateway
# uses further down — the function ARN is deterministic so it doesn't need to exist yet.
FUNCTION_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"
cat > /tmp/self-invoke-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "lambda:InvokeFunction",
      "Resource": "${FUNCTION_ARN}"
    }
  ]
}
EOF
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "wb-scheduler-self-invoke" \
  --policy-document file:///tmp/self-invoke-policy.json >/dev/null
echo "Attached self-invoke policy so the function can asynchronously call itself."

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
    --timeout 120 \
    --memory-size 1024 \
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
      --timeout 120 \
      --memory-size 1024 \
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
echo "Lambda function $FUNCTION_NAME ready (120s timeout, 1024MB)."

FUNCTION_ARN=$(aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" --query 'Configuration.FunctionArn' --output text)

echo "== Removing the Lambda Function URL (network-blocked, no longer used) =="
aws lambda delete-function-url-config --function-name "$FUNCTION_NAME" --region "$REGION" >/dev/null 2>&1 \
  && echo "Deleted Function URL config." \
  || echo "(no Function URL config to remove, skipping)"
aws lambda remove-permission --function-name "$FUNCTION_NAME" --statement-id "FunctionURLAllowPublicAccess" --region "$REGION" >/dev/null 2>&1 \
  && echo "Removed Function URL invoke permission." \
  || echo "(no Function URL permission to remove, skipping)"

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
  # This no longer matters for extraction itself (that now runs async, off this timeout
  # entirely) but the kickoff call (/extract-from-s3) and every other route still route
  # through here, so it's still worth setting to the max for headroom.
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
  echo "Reusing integration $INTEGRATION_ID"
fi

for ROUTE in "GET /clients" "PUT /clients" "POST /extract-pdf" "POST /get-upload-url" "POST /extract-from-s3" "GET /job/{job_id}"; do
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

echo ""
echo "================================================================"
echo " Deployment complete."
echo " API Gateway base URL:  $API_URL"
echo ""
echo " Paste this URL into the Scheduler tool's Settings tab (only one"
echo " field needed now — the Function URL field has been removed)."
echo "================================================================"
echo ""

if [ -z "$ANTHROPIC_API_KEY" ]; then
  echo "NOTE: ANTHROPIC_API_KEY was not set on this run — if it's not already set from a"
  echo "previous deploy, extraction jobs will fail with a clear error until you run:"
  echo "  bash deploy.sh sk-ant-api03-xxxx"
  echo "or:"
  echo "  ANTHROPIC_API_KEY=sk-ant-... bash set-api-key.sh"
  echo ""
fi

echo "== Smoke test: GET /clients =="
curl -s "${API_URL}/clients"
echo ""
echo "== Smoke test: POST /get-upload-url =="
curl -s -X POST "${API_URL}/get-upload-url"
echo ""
echo "== Smoke test: POST /extract-from-s3 with a bogus key (expect a clean 400) =="
curl -s -X POST "${API_URL}/extract-from-s3" -H "Content-Type: application/json" -d '{"s3Key":"bogus"}'
echo ""
echo "== Smoke test: GET /job/{bogus-id} (expect a clean 404) =="
curl -s "${API_URL}/job/00000000-0000-0000-0000-000000000000"
echo ""
echo "Note: none of the above exercises a real extraction end-to-end (that needs a real"
echo "PDF uploaded through the actual frontend). After deploying, upload a real content"
echo "calendar through https://wbmedia-au.github.io/Scheduler and confirm it completes."
