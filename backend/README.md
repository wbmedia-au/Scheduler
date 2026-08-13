# WB Media Scheduler — backend deploy

Three files, run in AWS CloudShell:

- `lambda_function.py` — the Lambda code (GET/PUT /clients, POST /extract-pdf)
- `deploy.sh` — creates/updates the IAM role, Lambda function, and HTTP API (API Gateway v2) with CORS
- `set-api-key.sh` — sets/rotates just the `ANTHROPIC_API_KEY` env var later

## Steps

1. Go to the AWS Console (logged in as account `967307909838`), region **Sydney (ap-southeast-2)**.
2. Open **CloudShell** (icon in the top nav bar).
3. Upload all three files into CloudShell: Actions menu (⋮) → **Upload file** → select `lambda_function.py`, `deploy.sh`, `set-api-key.sh`. They land in your CloudShell home directory. (If you're deploying from a clone of this repo, just `cd backend/` instead.)
4. Run:
   ```bash
   chmod +x deploy.sh set-api-key.sh
   bash deploy.sh
   ```
5. At the end it prints an **API Gateway base URL**, e.g.
   `https://abc123xyz.execute-api.ap-southeast-2.amazonaws.com`
   and runs a smoke test against `GET /clients`.
6. Paste that URL into the Scheduler tool's **Settings** tab (`https://wbmedia-au.github.io/Scheduler`).
7. When you have your Anthropic API key ready:
   ```bash
   ANTHROPIC_API_KEY=sk-ant-api03-xxxx bash set-api-key.sh
   ```
   Until this runs, `/extract-pdf` will return a clear error; `/clients` works immediately.

`deploy.sh` is safe to re-run — it updates existing resources (role, function, API, routes) instead of failing on them, so re-running it after step 7 or after any code change is fine.

## What gets created

- IAM role `wb-scheduler-lambda-role` — basic Lambda execution (CloudWatch Logs) + an inline policy scoped to only `s3:GetObject`/`s3:PutObject` on `s3://wbmedia-assets-967307909838-ap-southeast-2-an/scheduler/clients.json`. Nothing else in the bucket is touched.
- Lambda function `wb-scheduler-api` — Python 3.12, 512MB, 28s timeout.
- HTTP API `wb-scheduler-api` (API Gateway v2) with native CORS restricted to `https://wbmedia-au.github.io`, routes `GET /clients`, `PUT /clients`, `POST /extract-pdf`, `$default` auto-deploy stage.

## Known limitation: 30-second ceiling on /extract-pdf

API Gateway HTTP APIs hard-cap integration timeouts at 30 seconds — this cannot be raised, even on AWS's side. The Lambda function is set to a 28s timeout so it fails cleanly rather than being cut off mid-response by API Gateway.

For a typical content calendar (10-20 post slides) this is comfortably enough. If you regularly work with much larger calendars and start seeing extraction time out, the fix is to move `/extract-pdf` off API Gateway onto a **Lambda Function URL** (same Lambda, a second entry point, no 30s ceiling — up to 15 minutes) — a small, self-contained follow-up change if/when it comes up. Not built now since it's not needed for the current workflow.

## Payload size limit

PDFs are sent as base64 in the POST body. Lambda's synchronous invoke limit is 6MB, so the backend rejects PDFs whose base64 form exceeds ~5MB of original file size. The frontend warns before upload if a file is likely to hit this.
