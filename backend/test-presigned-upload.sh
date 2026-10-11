#!/usr/bin/env bash
# WB Media Scheduler — presigned-URL upload diagnostic
#
# Proves, independently of the browser and your office network, whether the
# deployed /get-upload-url + S3 PUT flow actually works: it generates a large
# test file, requests a real presigned URL from the live API, PUTs it with
# curl from inside CloudShell (so no corporate proxy/firewall/browser
# extension in the loop), then asks S3 directly whether the object exists.
#
# Run this in the same AWS CloudShell session you used for deploy.sh, after
# deploying. Safe to re-run — it cleans up the test object it creates either
# way.
#
# Usage:
#   bash test-presigned-upload.sh [api-base-url] [size-mb]
#   (defaults: discovers the API URL from the "wb-scheduler-api" HTTP API,
#   80MB test file to match real Canva export sizes)

set -euo pipefail

REGION="ap-southeast-2"
API_NAME="wb-scheduler-api"
SIZE_MB="${2:-80}"

API_URL="${1:-}"
if [ -z "$API_URL" ]; then
  API_ID=$(aws apigatewayv2 get-apis --region "$REGION" --query "Items[?Name=='${API_NAME}'].ApiId" --output text)
  if [ -z "$API_ID" ] || [ "$API_ID" == "None" ]; then
    echo "ERROR: Could not auto-discover the API Gateway URL. Pass it explicitly:" >&2
    echo "  bash test-presigned-upload.sh https://xxxxxxxxxx.execute-api.ap-southeast-2.amazonaws.com" >&2
    exit 1
  fi
  API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com"
fi
echo "Using API: $API_URL"

TEST_FILE="/tmp/wb-presigned-test-${SIZE_MB}mb.pdf"
echo ""
echo "== Generating a ${SIZE_MB}MB test file (matches real 75-81MB Canva exports) =="
# A real %PDF header plus padding is enough to exercise the upload path end to end;
# this script tests the transport, not PDF parsing.
{ printf '%%PDF-1.4\n%%%%\n'; head -c "$((SIZE_MB * 1024 * 1024))" /dev/urandom; } > "$TEST_FILE"
ACTUAL_SIZE=$(du -h "$TEST_FILE" | cut -f1)
echo "Created $TEST_FILE ($ACTUAL_SIZE)"

echo ""
echo "== Requesting a presigned upload URL from the live API =="
RESPONSE=$(curl -s -X POST "${API_URL}/get-upload-url")
echo "Response: $RESPONSE"

UPLOAD_URL=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['uploadUrl'])")
S3_KEY=$(echo "$RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['s3Key'])")
BUCKET=$(echo "$UPLOAD_URL" | python3 -c "import sys; from urllib.parse import urlparse; print(urlparse(sys.stdin.read().strip()).netloc.split('.s3.')[0])")

echo ""
echo "Presigned URL host:   $(echo "$UPLOAD_URL" | python3 -c "import sys; from urllib.parse import urlparse; print(urlparse(sys.stdin.read().strip()).netloc)")"
echo "S3 key:                $S3_KEY"
if echo "$UPLOAD_URL" | grep -q 'X-Amz-Algorithm=AWS4-HMAC-SHA256'; then
  echo "Signature version:     SigV4 (correct)"
else
  echo "Signature version:     NOT SigV4 — the fix did not deploy correctly, stop here and redeploy."
  exit 1
fi
if echo "$UPLOAD_URL" | grep -qE '^https://[^/]+\.s3\.[a-z0-9-]+\.amazonaws\.com/'; then
  echo "Addressing style:      virtual-hosted, region-qualified (correct)"
else
  echo "Addressing style:      NOT virtual-hosted/region-qualified — the fix did not deploy correctly, stop here and redeploy."
  exit 1
fi

echo ""
echo "== PUTting the ${SIZE_MB}MB file directly to S3 via curl (bypasses browser + office network) =="
HTTP_CODE=$(curl -s -o /tmp/wb-presigned-put-response.txt -w '%{http_code}' -X PUT --upload-file "$TEST_FILE" "$UPLOAD_URL")
echo "PUT response HTTP status: $HTTP_CODE"
if [ "$HTTP_CODE" != "200" ]; then
  echo "S3 response body:"
  cat /tmp/wb-presigned-put-response.txt
  echo ""
  echo "RESULT: FAIL — the PUT itself was rejected by S3 (not a silent-200 case)."
  rm -f "$TEST_FILE"
  exit 1
fi

echo ""
echo "== Confirming the object actually landed in S3 (head-object) =="
if aws s3api head-object --bucket "$BUCKET" --key "$S3_KEY" --region "$REGION" > /tmp/wb-presigned-head.json 2>&1; then
  REMOTE_SIZE=$(python3 -c "import json; print(json.load(open('/tmp/wb-presigned-head.json'))['ContentLength'])")
  LOCAL_SIZE=$(stat -c%s "$TEST_FILE" 2>/dev/null || stat -f%z "$TEST_FILE")
  echo "Object exists in S3. Size in S3: $REMOTE_SIZE bytes. Local file size: $LOCAL_SIZE bytes."
  if [ "$REMOTE_SIZE" == "$LOCAL_SIZE" ]; then
    echo ""
    echo "RESULT: PASS — the presigned-URL upload fix is confirmed working at the AWS level."
    echo "A PUT that returns 200 now reliably produces a real, correctly-sized object in S3."
  else
    echo ""
    echo "RESULT: FAIL — object exists but size doesn't match (truncated upload?)."
  fi
else
  echo "head-object failed:"
  cat /tmp/wb-presigned-head.json
  echo ""
  echo "RESULT: FAIL — PUT returned 200 but the object is NOT in S3. This is the original bug,"
  echo "still present. Since this script bypasses the browser and your office network"
  echo "entirely, that would point to something AWS-side (bucket policy, replication,"
  echo "lifecycle rule deleting it immediately, etc.) rather than a client/network issue."
fi

echo ""
echo "== Cleaning up test object and local file =="
aws s3 rm "s3://${BUCKET}/${S3_KEY}" --region "$REGION" >/dev/null 2>&1 || true
rm -f "$TEST_FILE" /tmp/wb-presigned-put-response.txt /tmp/wb-presigned-head.json
echo "Done."
