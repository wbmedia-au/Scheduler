# WB Media Scheduler — backend deploy

Four files, run in AWS CloudShell:

- `lambda_function.py` — the Lambda code (`GET/PUT /clients`, `POST /get-upload-url`, `POST /extract-from-s3`, plus the legacy `POST /extract-pdf`)
- `deploy.sh` — creates/updates the IAM role, S3 CORS, Lambda function, HTTP API (API Gateway v2), and Lambda Function URL
- `set-api-key.sh` — sets/rotates just the `ANTHROPIC_API_KEY` env var later
- This file

## Upload flow (fixes the API Gateway 6MB payload limit)

The old flow read the whole PDF into base64 and POSTed it through API Gateway — API Gateway hard-caps request payloads well under what a multi-page Canva export can reach. The new flow bypasses that entirely:

1. Frontend calls `POST /get-upload-url` → Lambda returns a presigned S3 `PUT` URL (5 min TTL) for a random key under `scheduler/uploads/`.
2. Frontend `PUT`s the raw PDF file straight to S3 using that URL — this traffic never touches API Gateway or Lambda, so there's no practical size limit.
3. Frontend calls `POST /extract-from-s3` with `{"s3Key": "..."}` (now via the Lambda Function URL, see below) → Lambda reads the object from S3, sends it to the Anthropic API, and returns the extracted posts.
4. Lambda deletes the temporary upload from S3 once extraction finishes (success or failure), so nothing accumulates under `scheduler/uploads/`.

The old `POST /extract-pdf` (base64-in-body) endpoint is left in place for backwards compatibility but the frontend no longer calls it.

## Steps

1. Go to the AWS Console (logged in as account `967307909838`), region **Sydney (ap-southeast-2)**.
2. Open **CloudShell** (icon in the top nav bar).
3. Upload `lambda_function.py`, `deploy.sh`, and `set-api-key.sh` into CloudShell: Actions menu (⋮) → **Upload file**. (If you're deploying from a clone of this repo, just `cd backend/` instead.)
4. Run:
   ```bash
   chmod +x deploy.sh set-api-key.sh
   bash deploy.sh
   ```
5. It re-deploys the existing `wb-scheduler-api` function and `j261orli37` API in place, creates/updates the Function URL, prints both URLs, and runs smoke tests against all three endpoints.
6. Paste **both** URLs into the Scheduler tool's Settings tab — API Gateway base URL and PDF Extraction Function URL are separate fields.
7. If you haven't already set your Anthropic key on this function: `ANTHROPIC_API_KEY=sk-ant-api03-xxxx bash set-api-key.sh`

`deploy.sh` is safe to re-run — it updates existing resources (role, policy, CORS, function, API, routes, Function URL) instead of failing on them.

## What changed in the previous update (presigned S3 upload)

- IAM role `wb-scheduler-lambda-role`: the old `wb-scheduler-clients-json-access` inline policy is removed and replaced with `wb-scheduler-s3-access`, covering both `s3:GetObject`/`s3:PutObject` on `scheduler/clients.json` **and** `s3:PutObject`/`s3:GetObject`/`s3:DeleteObject` on `scheduler/uploads/*`.
- S3 bucket CORS: a `PUT` rule for `https://wbmedia-au.github.io` is merged into whatever CORS configuration already exists on the bucket (existing rules, e.g. for CloudFront, are preserved — the script reads the current config first and only adds/replaces its own rule).
- Lambda timeout raised from 28s to 60s.
- Lambda function code adds `POST /get-upload-url` and `POST /extract-from-s3`; `/extract-pdf` is unchanged and still works.

## `/extract-from-s3` has moved to a Lambda Function URL (no timeout ceiling)

The API Gateway HTTP API's 30-second integration timeout turned out to be a real problem in practice — large calendars were taking ~42 seconds to extract and getting a 503. That ceiling is fixed by AWS and cannot be configured higher no matter what the Lambda's own timeout is set to, so raising the Lambda timeout to 60s (previous update) didn't fix it on its own, as flagged at the time.

The actual fix, now deployed: `POST /extract-from-s3` is served from a **Lambda Function URL** instead of API Gateway. Function URLs support up to the Lambda's own timeout (currently 60s, room to raise further if needed) with no separate gateway-imposed ceiling, and have their own native CORS config, same idea as API Gateway's.

What changed:
- `deploy.sh` creates/updates a Function URL on `wb-scheduler-api` (`auth-type NONE`, CORS restricted to `https://wbmedia-au.github.io`, `POST` only) and grants public invoke permission via a separate `lambda:InvokeFunctionUrl` resource policy (distinct from the `lambda:InvokeFunction` permission API Gateway uses — this doesn't touch the `wb-scheduler-lambda-role` execution role, since that role governs what the function can *access* — S3 — not who can *invoke* it).
- The old `POST /extract-from-s3` route on API Gateway is deleted by `deploy.sh` if present, so there's exactly one place this endpoint lives.
- `GET /clients`, `PUT /clients`, and `POST /get-upload-url` are untouched, still on API Gateway.
- **No Lambda code changes** — Function URLs use the same event/response shape as API Gateway HTTP API v2 (`requestContext.http.method`, `rawPath`, etc.), so the existing routing in `lambda_handler` works unchanged.
- The frontend's Settings tab now has a second field, **PDF Extraction Function URL**, alongside the API Gateway URL — Function URLs get a random AWS-assigned subdomain at creation time that can't be known in advance, so it has to be pasted in the same way the API Gateway URL is. Everything else about the workflow is unchanged.

After running `deploy.sh`, paste **both** printed URLs into Settings (the API Gateway URL is unchanged if you didn't recreate the API; the Function URL is new).
