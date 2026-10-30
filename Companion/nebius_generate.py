#!/usr/bin/env python3
"""One bounded Nemotron source construction through Nebius Token Factory.

The companion runs this child in a copied candidate workspace. Only the two
authorized source files may be written; the companion independently verifies
the entire workspace boundary before admitting the candidate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

FILES = ("queued/queue.go", "queued/worker.go")
CONTEXT = ("queued/queue.go", "queued/worker.go", "queued/domain.go",
           "queued/queued_test.go", "queued/support_test.go", ".trajectory/intent.json")
DEFAULT_ENDPOINT = "https://api.tokenfactory.nebius.com/v1"
HOSTS = {"api.tokenfactory.nebius.com", "api.tokenfactory.us-central1.nebius.com"}


def endpoint_url(value):
    value = value.rstrip("/")
    parts = urlsplit(value)
    if (parts.scheme != "https" or parts.netloc not in HOSTS or parts.path != "/v1"
            or parts.query or parts.fragment):
        raise ValueError("official Nebius Token Factory HTTPS endpoint required")
    return value + "/chat/completions"


def extract_candidate(response):
    try:
        choices = response["choices"]
        if len(choices) != 1 or choices[0]["finish_reason"] != "stop":
            reason = choices[0].get("finish_reason") if len(choices) == 1 else "choice_count"
            raise ValueError(f"Nemotron response did not finish: {reason}")
        value = json.loads(choices[0]["message"]["content"])
        if not isinstance(value, dict) or set(value) != set(FILES):
            keys = sorted(value) if isinstance(value, dict) else type(value).__name__
            raise ValueError(f"Nemotron candidate must contain exactly the two authorized files; keys={keys}")
        if any(not isinstance(value[p], str) or not value[p].startswith("package queued\n")
               or len(value[p].encode()) > 32768 for p in FILES):
            shapes = {p: {"length": len(value[p]) if isinstance(value[p], str) else None,
                          "package_prefix": isinstance(value[p], str) and value[p].startswith("package queued\n")}
                      for p in FILES}
            raise ValueError(f"Nemotron candidate source shape invalid: {shapes}")
        return value
    except (KeyError, IndexError, TypeError, json.JSONDecodeError) as exc:
        raise ValueError("invalid Nemotron candidate response") from exc


def apply_candidate(workspace, files):
    if (set(files) != set(FILES) or any(not isinstance(files[p], str)
                                       or not files[p].startswith("package queued\n")
                                       or len(files[p].encode()) > 32768 for p in FILES)):
        raise ValueError("candidate outside two-file Go source boundary")
    workspace = Path(workspace).resolve()
    for relative in FILES:
        target = workspace / relative
        if target.is_symlink() or not target.is_file() or target.resolve().parent != (workspace / "queued").resolve():
            raise ValueError("candidate source path unavailable")
    for relative in FILES:
        (workspace / relative).write_text(files[relative])


def generate(workspace, prompt_path, model, invocation_id):
    key = os.environ.get("NEBIUS_API_KEY", "").strip()
    if not key:
        raise RuntimeError("NEBIUS_API_KEY is not configured")
    if not model.lower().startswith("nvidia/") or "nemotron" not in model.lower():
        raise ValueError("NVIDIA Nemotron model required")
    workspace = Path(workspace).resolve()
    prompt = Path(prompt_path).read_text()
    context = "\n\n".join(f"### {name}\n{(workspace / name).read_text()}" for name in CONTEXT)
    payload = {"model": model, "temperature": 0, "max_tokens": 12000,
               "response_format": {"type": "json_object"},
               "messages": [
                   {"role": "system", "content": "Implement the accepted Trajectory policy. Return exactly one JSON object with the complete source strings for queued/queue.go and queued/worker.go. Change no other files. Preserve package queued, Go API signatures, tenant isolation, and audit-before-release. Do not claim checks passed; the companion runs them separately."},
                   {"role": "user", "content": prompt + "\n\nCURRENT SOURCE AND PROTECTED CONTRACT\n" + context},
               ]}
    body = json.dumps(payload).encode()
    request_hash = hashlib.sha256(body).hexdigest()
    request = Request(endpoint_url(os.environ.get("NEBIUS_BASE_URL", DEFAULT_ENDPOINT)),
                      data=body, headers={"Authorization": "Bearer " + key,
                                          "Content-Type": "application/json"})
    try:
        with urlopen(request, timeout=120) as result:
            response = json.load(result)
            status = result.status
            request_id = result.headers.get("x-request-id")
    except HTTPError as exc:
        detail = exc.read(2048).decode(errors="replace").replace(key, "[REDACTED]")
        raise RuntimeError(f"Nebius HTTP {exc.code}: {detail}") from None
    files = extract_candidate(response)
    apply_candidate(workspace, files)
    print(json.dumps({"type": "nebius.response", "invocation_id": invocation_id,
                      "model": response.get("model"), "response_id": response.get("id"),
                      "usage": response.get("usage"), "http_status": status,
                      "request_id": request_id, "request_sha256": request_hash,
                      "candidate_sha256": {name: hashlib.sha256(files[name].encode()).hexdigest()
                                           for name in FILES}}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--invocation-id", required=True)
    args = parser.parse_args()
    try:
        generate(args.workspace, args.prompt, args.model, args.invocation_id)
    except (OSError, ValueError, RuntimeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
