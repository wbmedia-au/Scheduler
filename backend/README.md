# WB Media Scheduler — backend deploy

Four files, run in AWS CloudShell:

- `lambda_function.py` — the Lambda code (`GET/PUT /clients`, `POST /get-upload-url`, `POST /extract-from-s3`, plus the legacy `POST /extract-pdf`)
- `deploy.sh` — creates/updates the IAM role, S3 CORS, Lambda function, and HTTP API (API Gateway v2) with CORS
- `set-api-key.sh` — sets/rotates just the `ANTHROPIC_API_KEY` env var later
- This file

## Upload flow (fixes the API Gateway 6MB payload limit)

The old flow read the whole PDF into base64 and POSTed it through API Gateway — API Gateway hard-caps request payloads well under what a multi-page Canva export can reach. The new flow bypasses that entirely:

1. Frontend calls `POST /get-upload-url` → Lambda returns a presigned S3 `PUT` URL (5 min TTL) for a random key under `scheduler/uploads/`.
2. Frontend `PUT`s the raw PDF file straight to S3 using that URL — this traffic never touches API Gateway or Lambda, so there's no practical size limit.
3. Frontend calls `POST /extract-from-s3` with `{"s3Key": "..."}` → Lambda reads the object from S3, sends it to the Anthropic API, and returns the extracted posts.
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
5. It re-deploys the existing `wb-scheduler-api` function and `j261orli37` API in place, prints the API Gateway base URL, and runs smoke tests against `GET /clients` and `POST /get-upload-url`.
6. The Settings tab in the Scheduler tool doesn't need updating if the URL is unchanged — this is an in-place update to the same API.
7. If you haven't already set your Anthropic key on this function: `ANTHROPIC_API_KEY=sk-ant-api03-xxxx bash set-api-key.sh`

`deploy.sh` is safe to re-run — it updates existing resources (role, policy, CORS, function, API, routes) instead of failing on them.

## What changed in this update

- IAM role `wb-scheduler-lambda-role`: the old `wb-scheduler-clients-json-access` inline policy is removed and replaced with `wb-scheduler-s3-access`, covering both `s3:GetObject`/`s3:PutObject` on `scheduler/clients.json` **and** `s3:PutObject`/`s3:GetObject`/`s3:DeleteObject` on `scheduler/uploads/*`.
- S3 bucket CORS: a `PUT` rule for `https://wbmedia-au.github.io` is merged into whatever CORS configuration already exists on the bucket (existing rules, e.g. for CloudFront, are preserved — the script reads the current config first and only adds/replaces its own rule).
- Lambda timeout raised from 28s to 60s.
- Lambda function code adds `POST /get-upload-url` and `POST /extract-from-s3`; `/extract-pdf` is unchanged and still works.

## Important: the 60s Lambda timeout does not raise the client-facing time limit

This is worth reading before assuming large PDFs are fully unblocked.

API Gateway **HTTP APIs hard-cap integration timeouts at 30 seconds** — this is fixed by AWS and cannot be configured higher, regardless of the Lambda function's own timeout. `deploy.sh` sets the integration timeout to 30000ms (the maximum allowed). The Lambda's 60s timeout only matters for execution that happens *after* API Gateway would have already returned a 504 to the browser — it does not extend what the caller experiences.

Concretely:
- **The upload step (`PUT` to S3) is now unlimited** — this was the actual "PDFs over 6MB fail" bug, and it's fully fixed. Upload a PDF of any reasonable size and it will go straight to S3 with no API Gateway involvement.
- **The extraction step (`POST /extract-from-s3`) still goes through API Gateway**, so it's still bound by the ~30s ceiling — same as before this change. Removing the size cap on uploads means people can now upload much larger PDFs than before, which makes it *more* likely (not less) that a large calendar's extraction call alone will take longer than 30 seconds and time out, even though the upload itself succeeded.

For a typical calendar (10-20 slides) 30 seconds is comfortably enough, and nothing about this deploy makes that case worse. But if you start seeing `/extract-from-s3` fail on genuinely large PDFs, the 60s Lambda timeout won't be what fixes it — the actual fix is moving `/extract-from-s3` off API Gateway onto a **Lambda Function URL** (same function, a second entry point with its own CORS config and up to 15 minutes timeout). That's a small, self-contained follow-up, not built here since it wasn't requested — flag it if you hit this in practice.
