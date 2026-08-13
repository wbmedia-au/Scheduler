import json
import os
import re
import urllib.error
import urllib.request

import boto3

S3_BUCKET = os.environ["S3_BUCKET"]
S3_KEY = os.environ["S3_KEY"]
ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
ANTHROPIC_MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-5")
ANTHROPIC_VERSION = "2023-06-01"
ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
ALLOWED_ORIGIN = os.environ.get("ALLOWED_ORIGIN", "https://wbmedia-au.github.io")

# Lambda synchronous invoke payload limit is 6MB; base64 inflates raw bytes by ~1.33x.
MAX_PDF_B64_CHARS = 7_000_000

EXTRACTION_PROMPT = """Please extract all posts from this WB Media content calendar PDF and return the data in this exact JSON format with no extra text or markdown:

{"posts":[{"label":"WEEK 1: POST 01","date":"13.05.26","post_type":"CAROUSEL","caption":"full caption including all emojis and hashtags","dropbox_url":"https://www.dropbox.com/..."}]}

Include every post slide. Skip cover pages, grid previews and feedback slides. Include complete captions with all emojis and hashtags. For dropbox_url, extract the Dropbox link from the slide if one exists (look for "Dropbox Video Link", "Dropbox Link", or any dropbox.com URL on the slide) — if no Dropbox link is present on the slide, use an empty string "". Return only the JSON — no explanation before or after."""

s3 = boto3.client("s3")

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


def handle_extract_pdf(event):
    if not ANTHROPIC_API_KEY:
        return _response(500, {"error": "ANTHROPIC_API_KEY is not configured on the server yet"})

    try:
        payload = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"error": "Invalid JSON body"})

    pdf_b64 = payload.get("pdf_base64", "")
    if not pdf_b64:
        return _response(400, {"error": "Missing 'pdf_base64' field"})

    if len(pdf_b64) > MAX_PDF_B64_CHARS:
        return _response(413, {"error": "PDF is too large to process (max ~5MB). Please compress or split it."})

    request_body = json.dumps(
        {
            "model": ANTHROPIC_MODEL,
            "max_tokens": 8192,
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "document",
                            "source": {
                                "type": "base64",
                                "media_type": "application/pdf",
                                "data": pdf_b64,
                            },
                        },
                        {"type": "text", "text": EXTRACTION_PROMPT},
                    ],
                }
            ],
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
        with urllib.request.urlopen(req, timeout=25) as resp:
            resp_data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")
        return _response(502, {"error": f"Anthropic API error ({e.code}): {detail}"})
    except Exception as e:
        return _response(502, {"error": f"Failed to reach Anthropic API: {e}"})

    try:
        text = "".join(
            block.get("text", "") for block in resp_data.get("content", []) if block.get("type") == "text"
        )
        posts_json = _extract_json_block(text)
    except Exception as e:
        return _response(502, {"error": f"Could not parse Claude's response as JSON: {e}"})

    if "posts" not in posts_json or not isinstance(posts_json["posts"], list):
        return _response(502, {"error": "Claude's response did not contain a 'posts' array"})

    return _response(200, posts_json)


def lambda_handler(event, context):
    method, path = _method_and_path(event)

    if method == "OPTIONS":
        return _response(200, {})

    if path == "/clients" and method == "GET":
        return handle_get_clients()
    if path == "/clients" and method == "PUT":
        return handle_put_clients(event)
    if path == "/extract-pdf" and method == "POST":
        return handle_extract_pdf(event)

    return _response(404, {"error": f"No route for {method} {path}"})
