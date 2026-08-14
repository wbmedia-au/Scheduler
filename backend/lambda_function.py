import base64
import datetime
import io
import json
import os
import re
import urllib.error
import urllib.request
import uuid

import boto3
import pypdf

S3_BUCKET = os.environ["S3_BUCKET"]
S3_KEY = os.environ["S3_KEY"]
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
ANTHROPIC_MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-5")
ANTHROPIC_VERSION = "2023-06-01"
ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "https://wbmedia-au.github.io")

UPLOADS_PREFIX = "scheduler/uploads/"
UPLOAD_KEY_RE = re.compile(r"^scheduler/uploads/[A-Za-z0-9-]+\.pdf$")

JOBS_PREFIX = "scheduler/jobs/"
JOB_ID_RE = re.compile(r"^[0-9a-fA-F-]{1,64}$")

# Lambda synchronous invoke payload limit is 6MB; base64 inflates raw bytes by ~1.33x.
# Only relevant to the legacy /extract-pdf endpoint. The async /extract-from-s3 flow has
# no such limit since the PDF bypasses API Gateway entirely via a presigned S3 upload.
MAX_PDF_B64_CHARS = 7_000_000

# Extracted PDF text sent to Anthropic. ~600k chars is roughly 150k tokens, comfortably
# under Claude's context window with room for the prompt and response.
MAX_EXTRACTED_TEXT_CHARS = 600_000

EXTRACTION_PROMPT = """Please extract all posts from this WB Media content calendar PDF and return the data in this exact JSON format with no extra text or markdown:

{"posts":[{"label":"WEEK 1: POST 01","date":"13.05.26","post_type":"CAROUSEL","caption":"full caption including all emojis and hashtags","dropbox_url":"https://www.dropbox.com/..."}]}

Include every post slide. Skip cover pages, grid previews and feedback slides. Include complete captions with all emojis and hashtags. For dropbox_url, extract the Dropbox link from the slide if one exists (look for "Dropbox Video Link", "Dropbox Link", or any dropbox.com URL on the slide) — if no Dropbox link is present on the slide, use an empty string "". Return only the JSON — no explanation before or after."""

s3 = boto3.client("s3")
lambda_client = boto3.client("lambda")

CORS_HEADERS = {
    "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
    "Access-Control-Allow-Headers": "content-type",
    "Access-Control-Allow-Methods": "GET,PUT,POST,OPTIONS",
}


def _response(status, body_obj):
    return {
        "statusCode": status,
        "headers": {**CORS_HEADERS, "Content-Type": "application/json"},
        "body": json.dumps(body_obj),
    }


def _method_and_path(event):
    http_ctx = event.get("requestContext", {}).get("http")
    if http_ctx:
        return http_ctx["method"], event.get("rawPath", "/")
    return event.get("httpMethod", "GET"), event.get("path", "/")


def _now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def handle_get_clients():
    try:
        obj = s3.get_object(Bucket=S3_BUCKET, Key=S3_KEY)
        body = obj["Body"].read().decode("utf-8")
        return _response(200, json.loads(body))
    except s3.exceptions.NoSuchKey:
        return _response(200, {"version": 1, "clients": []})
    except Exception as e:
        return _response(500, {"error": f"Failed to read clients.json: {e}"})


def handle_put_clients(event):
    try:
        payload = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON body"})

    if "clients" not in payload or not isinstance(payload["clients"], list):
        return _response(400, {"error": "Body must include a 'clients' array"})

    payload.setdefault("version", 1)

    try:
        s3.put_object(
            Bucket=S3_BUCKET,
            Key=S3_KEY,
            Body=json.dumps(payload, indent=2).encode("utf-8"),
            ContentType="application/json",
        )
        return _response(200, {"success": True})
    except Exception as e:
        return _response(500, {"error": f"Failed to write clients.json: {e}"})


def _extract_json_block(text):
    stripped = text.strip()
    stripped = re.sub(r"^```(?:json)?\s*", "", stripped)
    stripped = re.sub(r"\s*```$", "", stripped)
    match = re.search(r"\{[\s\S]*\}", stripped)
    if not match:
        raise ValueError("No JSON object found in Claude's response")
    return json.loads(match.group(0))


def _call_anthropic_messages(content_blocks, timeout_seconds):
    """POSTs a single-turn message to the Anthropic Messages API and returns the parsed
    {"posts": [...]} object. Raises RuntimeError with a caller-friendly message on any
    failure — network, HTTP, or malformed-response."""
    if not ANTHROPIC_API_KEY:
        raise RuntimeError("ANTHROPIC_API_KEY is not configured on the server yet")

    request_body = json.dumps(
        {
            "model": ANTHROPIC_MODEL,
            "max_tokens": 8192,
            "messages": [{"role": "user", "content": content_blocks}],
        }
    ).encode("utf-8")

    req = urllib.request.Request(
        ANTHROPIC_URL,
        data=request_body,
        method="POST",
        headers={
            "x-api-key": ANTHROPIC_API_KEY,
            "anthropic-version": ANTHROPIC_VERSION,
            "content-type": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=timeout_seconds) as resp:
            resp_data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Anthropic API error ({e.code}): {detail}")
    except Exception as e:
        raise RuntimeError(f"Failed to reach Anthropic API: {e}")

    text = "".join(
        block.get("text", "") for block in resp_data.get("content", []) if block.get("type") == "text"
    )
    try:
        posts_json = _extract_json_block(text)
    except Exception as e:
        raise RuntimeError(f"Could not parse Claude's response as JSON: {e}")

    if "posts" not in posts_json or not isinstance(posts_json["posts"], list):
        raise RuntimeError("Claude's response did not contain a 'posts' array")

    return posts_json


def handle_extract_pdf(event):
    """Legacy endpoint: PDF arrives base64-encoded in the request body via API Gateway,
    and is sent to Claude as a native PDF document (not text-extracted). Kept for backwards
    compatibility; not used by the current frontend, which uses the async
    /extract-from-s3 + /job/{job_id} flow below. Still bound by API Gateway's 30s ceiling."""
    try:
        payload = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON body"})

    pdf_b64 = payload.get("pdf_base64", "")
    if not pdf_b64:
        return _response(400, {"error": "Missing 'pdf_base64' field"})

    if len(pdf_b64) > MAX_PDF_B64_CHARS:
        return _response(413, {"error": "PDF is too large for this endpoint. Use the upload flow instead."})

    content_blocks = [
        {"type": "document", "source": {"type": "base64", "media_type": "application/pdf", "data": pdf_b64}},
        {"type": "text", "text": EXTRACTION_PROMPT},
    ]
    try:
        posts_json = _call_anthropic_messages(content_blocks, timeout_seconds=25)
    except RuntimeError as e:
        return _response(502, {"error": str(e)})
    return _response(200, posts_json)


def handle_get_upload_url():
    key = f"{UPLOADS_PREFIX}{uuid.uuid4()}.pdf"
    try:
        upload_url = s3.generate_presigned_url(
            "put_object",
            Params={"Bucket": S3_BUCKET, "Key": key},
            ExpiresIn=300,
        )
    except Exception as e:
        return _response(500, {"error": f"Failed to generate upload URL: {e}"})

    return _response(200, {"uploadUrl": upload_url, "s3Key": key})


def _job_key(job_id):
    return f"{JOBS_PREFIX}{job_id}.json"


def _write_job(job_id, record):
    s3.put_object(
        Bucket=S3_BUCKET,
        Key=_job_key(job_id),
        Body=json.dumps(record).encode("utf-8"),
        ContentType="application/json",
    )


def handle_extract_from_s3(event):
    """Kicks off async extraction and returns immediately. Does the actual work of
    /extract-from-s3 from the caller's point of view, but only ever does ~3 fast S3/Lambda
    calls itself — the slow part (reading the PDF, calling Anthropic) happens in a second,
    asynchronously-invoked run of this same Lambda (see handle_async_extraction_job)."""
    try:
        payload = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON body"})

    s3_key = payload.get("s3Key", "")
    if not s3_key or not UPLOAD_KEY_RE.match(s3_key):
        return _response(400, {"error": "Invalid or missing 's3Key'"})

    job_id = str(uuid.uuid4())
    created_at = _now_iso()

    try:
        _write_job(job_id, {"status": "processing", "created_at": created_at})
    except Exception as e:
        return _response(500, {"error": f"Failed to create extraction job: {e}"})

    try:
        lambda_client.invoke(
            FunctionName=os.environ["AWS_LAMBDA_FUNCTION_NAME"],
            InvocationType="Event",
            Payload=json.dumps(
                {
                    "__async_job__": True,
                    "job_id": job_id,
                    "s3Key": s3_key,
                    "created_at": created_at,
                }
            ).encode("utf-8"),
        )
    except Exception as e:
        try:
            _write_job(
                job_id,
                {
                    "status": "error",
                    "message": f"Failed to start extraction: {e}",
                    "created_at": created_at,
                    "completed_at": _now_iso(),
                },
            )
        except Exception:
            pass
        return _response(500, {"error": f"Failed to start extraction job: {e}"})

    return _response(202, {"job_id": job_id, "status": "processing"})


def _extract_pdf_text(pdf_bytes):
    reader = pypdf.PdfReader(io.BytesIO(pdf_bytes))
    parts = []
    for i, page in enumerate(reader.pages):
        text = page.extract_text() or ""
        parts.append(f"--- Page {i + 1} ---\n{text}")
    return "\n\n".join(parts)


def handle_async_extraction_job(event):
    """Runs as a separate, asynchronously-invoked Lambda execution (InvocationType='Event'),
    so it gets its own full function timeout independent of however long the kickoff request
    took. Its return value is discarded by Lambda; all it can do is write the outcome to S3."""
    job_id = event.get("job_id")
    s3_key = event.get("s3Key")
    created_at = event.get("created_at") or _now_iso()

    if not job_id or not s3_key:
        return  # malformed self-invocation — nothing sensible to record

    def fail(message):
        try:
            _write_job(
                job_id,
                {
                    "status": "error",
                    "message": message,
                    "created_at": created_at,
                    "completed_at": _now_iso(),
                },
            )
        except Exception:
            pass

    try:
        try:
            obj = s3.get_object(Bucket=S3_BUCKET, Key=s3_key)
            pdf_bytes = obj["Body"].read()
        except Exception as e:
            fail(f"Could not read the uploaded PDF from S3: {e}")
            return

        try:
            pdf_text = _extract_pdf_text(pdf_bytes)
        except Exception as e:
            fail(f"Could not read this PDF's contents — it may be corrupted or password-protected: {e}")
            return

        if not pdf_text.strip():
            fail("No readable text was found in this PDF. It may be a scanned image with no text layer.")
            return

        if len(pdf_text) > MAX_EXTRACTED_TEXT_CHARS:
            fail(
                f"This PDF's text is too large for the extraction model in one pass "
                f"({len(pdf_text):,} characters). Please split it into smaller calendars."
            )
            return

        content_blocks = [
            {
                "type": "text",
                "text": f"{EXTRACTION_PROMPT}\n\n--- PDF TEXT (extracted page by page) ---\n{pdf_text}",
            }
        ]

        try:
            posts_json = _call_anthropic_messages(content_blocks, timeout_seconds=100)
        except RuntimeError as e:
            fail(str(e))
            return

        try:
            _write_job(
                job_id,
                {
                    "status": "complete",
                    "posts": posts_json["posts"],
                    "created_at": created_at,
                    "completed_at": _now_iso(),
                },
            )
        except Exception as e:
            fail(f"Extraction succeeded but saving the result failed: {e}")
    finally:
        # Always clean up the temporary upload, even if extraction failed, so
        # failed/retried uploads don't pile up in the bucket.
        try:
            s3.delete_object(Bucket=S3_BUCKET, Key=s3_key)
        except Exception:
            pass


def handle_get_job(job_id):
    if not job_id or not JOB_ID_RE.match(job_id):
        return _response(400, {"error": "Invalid job id"})
    try:
        obj = s3.get_object(Bucket=S3_BUCKET, Key=_job_key(job_id))
        body = obj["Body"].read().decode("utf-8")
        return _response(200, json.loads(body))
    except s3.exceptions.NoSuchKey:
        return _response(404, {"error": "Job not found. It may have expired, or the link is incorrect."})
    except Exception as e:
        return _response(500, {"error": f"Failed to read job status: {e}"})


def lambda_handler(event, context):
    # Self-invocation from handle_extract_from_s3 (InvocationType='Event') — not an
    # API Gateway request at all, so it's checked before any method/path routing.
    if event.get("__async_job__"):
        handle_async_extraction_job(event)
        return {"statusCode": 200}

    method, path = _method_and_path(event)

    if method == "OPTIONS":
        return _response(200, {})

    if path == "/clients" and method == "GET":
        return handle_get_clients()
    if path == "/clients" and method == "PUT":
        return handle_put_clients(event)
    if path == "/extract-pdf" and method == "POST":
        return handle_extract_pdf(event)
    if path == "/get-upload-url" and method == "POST":
        return handle_get_upload_url()
    if path == "/extract-from-s3" and method == "POST":
        return handle_extract_from_s3(event)
    if method == "GET" and path.startswith("/job/"):
        job_id = (event.get("pathParameters") or {}).get("job_id") or path[len("/job/"):]
        return handle_get_job(job_id)

    return _response(404, {"error": f"No route for {method} {path}"})
