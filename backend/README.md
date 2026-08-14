# WB Media Scheduler — backend deploy

Three files, run in AWS CloudShell:

- `lambda_function.py` — the Lambda code (`GET/PUT /clients`, `POST /get-upload-url`, `POST /extract-from-s3`, `GET /job/{job_id}`, plus the legacy `POST /extract-pdf`)
- `deploy.sh` — creates/updates the IAM role, S3 CORS, Lambda function, and HTTP API (API Gateway v2)
- `set-api-key.sh` — sets/rotates just the `ANTHROPIC_API_KEY` env var without a full redeploy

## Why this exists: the 30-second wall

API Gateway HTTP APIs hard-cap integration timeouts at 30 seconds — fixed by AWS, not configurable higher. Extraction on a real content calendar was taking 42+ seconds, so every large PDF hit a 503 partway through, no matter how high the Lambda's own timeout was set (that had already been tried). A Lambda Function URL was tried next to sidestep the API Gateway ceiling entirely, but it's blocked at the network level in this environment and isn't reachable. This deploy fixes it properly: extraction runs **asynchronously**, off any synchronous request's timeout entirely, and the frontend polls for the result. Nothing about this flow is bound by the 30-second ceiling — not because the ceiling was raised, but because nothing that takes 42 seconds is ever sitting inside a request/response cycle anymore.

## The async flow

1. Frontend calls `POST /get-upload-url` → presigned S3 `PUT` URL, same as before.
2. Frontend `PUT`s the PDF straight to S3 — no size limit, doesn't touch Lambda or API Gateway.
3. Frontend calls `POST /extract-from-s3` with `{"s3Key": "..."}`. The Lambda:
   - generates a `job_id`
   - writes `{"status":"processing","created_at":...}` to `s3://…/scheduler/jobs/{job_id}.json`
   - invokes **itself** asynchronously (`boto3` `lambda.invoke(..., InvocationType='Event')`) with the `job_id` and `s3Key`
   - returns `{"job_id":..., "status":"processing"}` immediately (202) — this whole round trip is a handful of S3/Lambda API calls, comfortably under a second, nowhere near 30s.
4. That second, async invocation is a completely separate Lambda execution with its own full 120-second timeout, untouched by whatever API Gateway is doing. It:
   - reads the PDF from S3
   - extracts its text with `pypdf` (pure Python, no compiled dependencies — safe to `pip install` on CloudShell and zip up regardless of CloudShell's own Python version, since it's not compiled against a specific interpreter)
   - sends the extracted text to the Anthropic API (as plain text, not as a PDF document block — see caveat below)
   - writes the final result to the same `scheduler/jobs/{job_id}.json`: `{"status":"complete","posts":[...]}` on success, `{"status":"error","message":"..."}` on any failure
   - deletes the uploaded PDF from S3 in a `finally`, regardless of outcome
5. Frontend polls `GET /job/{job_id}` every 3 seconds, showing "Still extracting… (Ns)", until it sees `complete` or `error`, or 5 minutes pass (then it shows a friendly timeout message and stops polling). If the browser is closed mid-extraction, that's fine — nothing needs to resume; staff just re-upload.

## Steps to deploy

1. AWS Console → account `967307909838` → region **Sydney (ap-southeast-2)** → **CloudShell**.
2. Upload `lambda_function.py`, `deploy.sh`, `set-api-key.sh` (Actions ⋮ → Upload file), or `cd backend/` if you cloned the repo.
3. Run, passing your Anthropic key as the first argument:
   ```bash
   chmod +x deploy.sh set-api-key.sh
   bash deploy.sh sk-ant-api03-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   ```
   (Omit the key only if it's already set from a previous run and you just want to redeploy code/infra — it'll warn you if extraction will fail without one.)
4. It prints the API Gateway base URL and runs smoke tests against `/clients`, `/get-upload-url`, `/extract-from-s3` (bad-key case), and `/job/{bogus-id}`.
5. Paste that URL into the Scheduler tool's Settings tab — **one field only**, same as originally. The "PDF Extraction Function URL" field from the previous deploy has been removed from the frontend; the Function URL infrastructure itself is deleted by this script too, since it's network-blocked and no longer used.
6. Upload a real content calendar through `https://wbmedia-au.github.io/Scheduler` to confirm a real end-to-end extraction — the deploy script's smoke tests check that endpoints respond correctly, not that a real 42-second extraction actually completes, which needs a real PDF.

`deploy.sh` is safe to re-run.

## What changed this round

- **IAM**: `wb-scheduler-s3-access` now also covers `scheduler/jobs/*` (`GetObject`/`PutObject`). A new inline policy, `wb-scheduler-self-invoke`, grants the role `lambda:InvokeFunction` on the function's own ARN — this is what lets the Lambda call itself asynchronously. (This is an identity-based policy on the execution role, separate from the resource-based `lambda:InvokeFunction`/`InvokeFunctionUrl` permissions used elsewhere for API Gateway/Function URL invocation.)
- **Lambda**: timeout raised 60s → 120s, memory raised 512MB → 1024MB, for headroom on the async worker (pypdf parsing + a ~100s Anthropic call budget + S3 I/O). Deployment package now bundles `pypdf` alongside `lambda_function.py` — `deploy.sh` does a `pip3 install --target build pypdf` before zipping.
- **API Gateway**: new route `GET /job/{job_id}`. All other routes unchanged.
- **Function URL removed**: `deploy.sh` deletes the Function URL config and its invoke permission. It was network-blocked in this environment and is no longer part of the architecture.
- **Frontend**: Settings is back to one field (API Gateway URL only). Upload now kicks off a job and polls it, with elapsed-time status messages, a 5-minute give-up, and no dependency on the browser staying open (nothing is resumed on reload by design — re-upload is the recovery path).

## Caveat: text extraction vs. native PDF reading

The previous synchronous flow sent the raw PDF to Claude as a native PDF document — Claude read pages visually, same as a human looking at the Canva export. This flow instead extracts text with `pypdf` first and sends that text to Claude. That's a deliberate tradeoff for a real reason: base64-encoding a whole PDF and sending it as a "document" content block is a large payload per request, and re-running that through the model on every retry/job is heavier than sending extracted text — but it does lose Claude's native visual reading order.

Canva PDF exports position text as individual elements rather than flowing document text, so `pypdf`'s extraction order can occasionally interleave overlapping text boxes in a way that doesn't match the visual slide layout — most calendars extract cleanly since each slide's caption/date/type are typically separate, non-overlapping text blocks, but a slide with dense overlapping design elements could come out slightly garbled in a way it wouldn't have under the old vision-based approach. Extracted text is grouped with `--- Page N ---` markers to at least preserve slide boundaries for Claude.

If this turns out to matter in practice — garbled captions on real calendars — the fix is straightforward: swap the async worker's `_extract_pdf_text` + text-based Anthropic call back to sending the base64 PDF as a `document` content block (exactly what `handle_extract_pdf`, still in the file, already does) inside `handle_async_extraction_job`. That keeps everything else (the job/polling architecture, the 30-second-ceiling fix) intact, and is worth doing if this becomes a real problem — not done now since it wasn't asked for and the synchronous timeout was the fire to put out.

## Other edge cases handled

- **PDF too large for Anthropic**: extracted text over ~600k characters (roughly 150k tokens) is rejected before calling Anthropic at all, with a message asking to split the calendar — well under Claude's context window, leaving room for the prompt and response.
- **Anthropic API error / malformed response**: caught and written to the job as a `status: "error"` with a descriptive message; the frontend surfaces it directly.
- **S3 read failure** (upload vanished, permissions issue, etc.): same — recorded as a job error, not a crash. Verified with a mocked-S3 test where the uploaded object is missing.
- **Job not found**: `GET /job/{job_id}` returns a clean 404 with a helpful message if the job_id doesn't exist (expired, typo, or a job that was never created).
- **Invalid `job_id` format**: rejected with 400 before ever touching S3 — a defensive check against path-traversal-shaped input in the job id, same pattern already used for `s3Key` validation.
- **Concurrent uploads from different staff**: every job gets its own random UUID and its own S3 object; nothing about the design shares state between jobs, so there's no cross-job interference regardless of how many run at once.
- **Malformed/failed self-invocation**: if the async `lambda.invoke` call itself fails (e.g. a permissions issue), the kickoff request writes an `error` status to the job before returning a 500, instead of leaving the job stuck at `processing` forever with no explanation.

All of the above (except the two AWS-side failure injections, which need real infrastructure) were exercised locally against the actual `lambda_function.py` with mocked S3/Lambda clients and a real multi-page PDF before this was shipped — full happy path, missing-job 404, invalid-job-id 400, bad-`s3Key` 400, and a missing-S3-object async failure all pass.
