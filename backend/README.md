# WB Media Scheduler — backend deploy

Four files, run in AWS CloudShell:

- `lambda_function.py` — the Lambda code (`GET/PUT /clients`, `POST /get-upload-url`, `POST /extract-from-s3`, `GET /job/{job_id}`, plus the legacy `POST /upload-pdf` and `POST /extract-pdf` for small files)
- `deploy.sh` — creates/updates the IAM role, S3 CORS, Lambda function, and HTTP API (API Gateway v2)
- `set-api-key.sh` — sets/rotates just the `ANTHROPIC_API_KEY` env var without a full redeploy
- `test-presigned-upload.sh` — diagnostic that proves the presigned-URL upload actually works, independent of the browser/office network (see below)

## The presigned-URL upload is fixed — and is back as the only path for real files

The real content calendars are 75-81MB. That number changes everything about this app's upload path, so it's worth being precise about what was tried and what's actually fixed now.

**What was wrong, concretely**: `handle_get_upload_url` built its S3 client with `boto3.client("s3")` and no explicit config. For `generate_presigned_url`, boto3's default in that configuration resolves to the legacy **SigV2** signing scheme against the bare, regionless `s3.amazonaws.com` endpoint — not the modern, AWS-recommended `{bucket}.s3.{region}.amazonaws.com` endpoint with **SigV4** signing. AWS deprecated SigV2 for S3 years ago; URLs built this way can accept the browser's PUT (hence the 200) while the object never actually commits. This was confirmed by generating presigned URLs locally with four different boto3 `Config()` combinations and inspecting the resulting URL — no AWS access needed, since presigned-URL generation is pure local request-signing, not a network call:

| Config | Resulting URL |
|---|---|
| `boto3.client("s3")` (previous code) | `https://s3.amazonaws.com/{bucket}/{key}?AWSAccessKeyId=...&Signature=...` — SigV2, no region |
| `Config(signature_version='s3v4')` only | still missing the region in the host |
| `Config(s3={'addressing_style':'virtual'})` only | region-qualified host, but still SigV2 |
| **`Config(signature_version='s3v4', s3={'addressing_style':'virtual'})`** | `https://{bucket}.s3.ap-southeast-2.amazonaws.com/{key}?X-Amz-Algorithm=AWS4-HMAC-SHA256...` — correct |

**The fix**: `handle_get_upload_url`'s S3 client now explicitly forces both settings together — neither alone was sufficient. This matches the hypothesis that the presigned URL was path-style/legacy-signed instead of the modern virtual-hosted SigV4 form almost exactly.

```python
s3 = boto3.client(
    "s3",
    region_name=AWS_REGION,
    config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}),
)
```

**Why this had to be the fix, not POST-through-Lambda**: a previous round of this backend replaced the presigned-URL flow with the browser POSTing base64 PDF JSON straight through API Gateway to Lambda. That's categorically unusable here — API Gateway HTTP APIs and Lambda's synchronous invoke both hard-cap request bodies at a small fraction of 75-81MB (roughly 5-10MB), a limit AWS does not let you raise. There's no tuning that fixes that; the presigned-URL approach, where the browser writes straight to S3 and never passes through Lambda or API Gateway at all, is the only architecture that can work for files this size. The base64 `/upload-pdf` endpoint is left in the code as a fallback for genuinely small files, but the frontend no longer uses it.

**What else changed alongside the fix**:
- `UPLOAD_URL_TTL_SECONDS` raised from 300s to 3600s (1 hour) — a slow connection uploading 75-81MB needs more headroom before the presigned URL expires than a quick small-file upload did.
- The async worker's Anthropic call timeout raised from 100s to 240s, and the Lambda function's own timeout/memory raised to 600s/3008MB (see `deploy.sh`) — more breathing room for downloading and parsing a much larger PDF before extraction even starts.
- `index.html`'s upload step reverted from `FileReader.readAsDataURL` + `POST /upload-pdf` back to `POST /get-upload-url` + a direct `PUT` to S3 — now done via `XMLHttpRequest` instead of `fetch`, so the UI can show live upload progress (`Uploading file.pdf… 42%`) instead of an indefinite spinner, which matters a lot more once uploads can take a while at 75-81MB.
- The client-side size check changed from a hard 5MB cap (meaningless now) to a 200MB sanity cap, comfortably above real file sizes with headroom.

**Verified before shipping**:
- Locally generated presigned URLs with the fixed S3 client against the real bucket name and confirmed the resulting URL is virtual-hosted, region-qualified, and SigV4-signed (`wbmedia-assets-967307909838-ap-southeast-2-an.s3.ap-southeast-2.amazonaws.com`, `X-Amz-Algorithm=AWS4-HMAC-SHA256`).
- Re-ran the full mocked-S3/Lambda test suite against the updated `lambda_function.py` — all existing cases still pass unchanged.
- Browser-tested (Playwright, mocked `fetch`/`XMLHttpRequest`) that the frontend now calls `/get-upload-url` then `PUT`s the file straight to the returned S3 URL with progress callbacks, never calls the retired `/upload-pdf` path, and that oversized files are rejected client-side with zero network calls.

**What I could not verify myself**: I don't have real AWS credentials in this environment, so I can't confirm the fix end-to-end against the actual S3 bucket over the real network — only that the signing logic is now provably correct. That's what `test-presigned-upload.sh` is for.

## New: `test-presigned-upload.sh` — definitive proof, independent of your browser or office network

Run this after deploying:

```bash
bash test-presigned-upload.sh
```

It generates an 80MB test file (matching real Canva export sizes), requests a real presigned URL from your live deployed API, `PUT`s it with `curl` from inside CloudShell itself — not your browser, not your office network, nothing in between — then calls `aws s3api head-object` to ask S3 directly whether the object is really there and the right size. It prints a clear PASS or FAIL and cleans up after itself either way.

This matters because the earlier symptom report ("PUT returns 200 but the file never lands") could in principle have had more than one explanation: a bug in the signing logic (now fixed and provable), or something about the specific browser/network path staff were uploading from (a corporate proxy or extension interfering with a large PUT, for instance). Running this script tells you definitively whether the AWS/S3 side is now solid — if it passes here but a real upload from the office still fails, that's a strong signal to look at the network path instead of the backend.

## Steps to deploy

1. AWS Console → account `967307909838` → region **Sydney (ap-southeast-2)** → **CloudShell**.
2. Upload `lambda_function.py`, `deploy.sh`, `set-api-key.sh`, `test-presigned-upload.sh` (Actions ⋮ → Upload file), or `cd backend/` if you cloned the repo.
3. Run, passing your Anthropic key as the first argument:
   ```bash
   chmod +x deploy.sh set-api-key.sh test-presigned-upload.sh
   bash deploy.sh sk-ant-api03-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   ```
   (Omit the key only if it's already set from a previous run and you just want to redeploy code/infra — it'll warn you if extraction will fail without one.)
4. It prints the API Gateway base URL and runs smoke tests against `/clients`, `/get-upload-url`, `/upload-pdf` (tiny base64 PDF), `/extract-from-s3` (bad-key case), and `/job/{bogus-id}`.
5. Run `bash test-presigned-upload.sh` to get a definitive pass/fail on the real upload path before testing from a browser.
6. Settings tab still needs just the one API Gateway URL field — no frontend settings change this round.
7. Upload a real 75-81MB content calendar through `https://wbmedia-au.github.io/Scheduler` to confirm a real end-to-end upload + extraction completes.

`deploy.sh` is safe to re-run.

## Why this exists: the 30-second wall

API Gateway HTTP APIs hard-cap integration timeouts at 30 seconds — fixed by AWS, not configurable higher. Extraction on a real content calendar was taking 42+ seconds, so every large PDF hit a 503 partway through, no matter how high the Lambda's own timeout was set (that had already been tried). A Lambda Function URL was tried next to sidestep the API Gateway ceiling entirely, but it's blocked at the network level in this environment and isn't reachable. This deploy fixes it properly: extraction runs **asynchronously**, off any synchronous request's timeout entirely, and the frontend polls for the result. Nothing about this flow is bound by the 30-second ceiling — not because the ceiling was raised, but because nothing that takes 42 seconds is ever sitting inside a request/response cycle anymore.

## The async flow

1. Frontend calls `POST /get-upload-url` → Lambda returns a presigned S3 PUT URL and the S3 key it points to.
2. Frontend `PUT`s the file straight to that URL (via `XMLHttpRequest`, with live progress) — this goes directly to S3, never through API Gateway or Lambda, so there's no payload-size ceiling at all.
3. Frontend calls `POST /extract-from-s3` with `{"s3Key": "..."}`. The Lambda:
   - generates a `job_id`
   - writes `{"status":"processing","created_at":...}` to `s3://…/scheduler/jobs/{job_id}.json`
   - invokes **itself** asynchronously (`boto3` `lambda.invoke(..., InvocationType='Event')`) with the `job_id` and `s3Key`
   - returns `{"job_id":..., "status":"processing"}` immediately (202) — this whole round trip is a handful of S3/Lambda API calls, comfortably under a second, nowhere near 30s.
4. That second, async invocation is a completely separate Lambda execution with its own full timeout (now 600s), untouched by whatever API Gateway is doing. It:
   - reads the PDF from S3
   - extracts its text with `pypdf` (pure Python, no compiled dependencies — safe to `pip install` on CloudShell and zip up regardless of CloudShell's own Python version, since it's not compiled against a specific interpreter)
   - sends the extracted text to the Anthropic API (as plain text, not as a PDF document block — see caveat below)
   - writes the final result to the same `scheduler/jobs/{job_id}.json`: `{"status":"complete","posts":[...]}` on success, `{"status":"error","message":"..."}` on any failure
   - deletes the uploaded PDF from S3 in a `finally`, regardless of outcome
5. Frontend polls `GET /job/{job_id}` every 3 seconds, showing "Still extracting… (Ns)", until it sees `complete` or `error`, or 5 minutes pass (then it shows a friendly timeout message and stops polling). If the browser is closed mid-extraction, that's fine — nothing needs to resume; staff just re-upload.

## Caveat: text extraction vs. native PDF reading

The original synchronous flow sent the raw PDF to Claude as a native PDF document — Claude read pages visually, same as a human looking at the Canva export. This flow instead extracts text with `pypdf` first and sends that text to Claude. That's a deliberate tradeoff for a real reason: base64-encoding a whole 75-81MB PDF and sending it as a "document" content block on every retry/job is a very large payload to push through the Anthropic API repeatedly — extracted text is far lighter — but it does lose Claude's native visual reading order.

Canva PDF exports position text as individual elements rather than flowing document text, so `pypdf`'s extraction order can occasionally interleave overlapping text boxes in a way that doesn't match the visual slide layout — most calendars extract cleanly since each slide's caption/date/type are typically separate, non-overlapping text blocks, but a slide with dense overlapping design elements could come out slightly garbled in a way it wouldn't have under the old vision-based approach. Extracted text is grouped with `--- Page N ---` markers to at least preserve slide boundaries for Claude.

If this turns out to matter in practice — garbled captions on real calendars — the fix is straightforward: swap the async worker's `_extract_pdf_text` + text-based Anthropic call back to sending the base64 PDF as a `document` content block (exactly what `handle_extract_pdf`, still in the file, already does) inside `handle_async_extraction_job`. That keeps everything else (the job/polling architecture, the 30-second-ceiling fix) intact, and is worth doing if this becomes a real problem — not done now since it wasn't asked for and the upload path was the fire to put out this round.

## Other edge cases handled

- **PDF too large for Anthropic**: extracted text over ~600k characters (roughly 150k tokens) is rejected before calling Anthropic at all, with a message asking to split the calendar — well under Claude's context window, leaving room for the prompt and response.
- **Anthropic API error / malformed response**: caught and written to the job as a `status: "error"` with a descriptive message; the frontend surfaces it directly.
- **S3 read failure** (upload vanished, permissions issue, etc.): same — recorded as a job error, not a crash. Verified with a mocked-S3 test where the uploaded object is missing.
- **Job not found**: `GET /job/{job_id}` returns a clean 404 with a helpful message if the job_id doesn't exist (expired, typo, or a job that was never created).
- **Invalid `job_id` format**: rejected with 400 before ever touching S3 — a defensive check against path-traversal-shaped input in the job id, same pattern already used for `s3Key` validation.
- **Concurrent uploads from different staff**: every job gets its own random UUID and its own S3 object; nothing about the design shares state between jobs, so there's no cross-job interference regardless of how many run at once.
- **Malformed/failed self-invocation**: if the async `lambda.invoke` call itself fails (e.g. a permissions issue), the kickoff request writes an `error` status to the job before returning a 500, instead of leaving the job stuck at `processing` forever with no explanation.
- **Oversized upload (client-side)**: `index.html` rejects files over 200MB before making any network call at all — well above real file sizes, just a sanity backstop.

All of the above (except the AWS-side failure injections, which need real infrastructure) were exercised locally against the actual `lambda_function.py` with mocked S3/Lambda clients and a real multi-page PDF before each round shipped.
