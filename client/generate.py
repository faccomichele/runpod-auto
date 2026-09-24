#!/usr/bin/env python3
"""Submit ComfyUI API workflows to a RunPod Serverless endpoint and save results.

The workflow is a ComfyUI "Workflow > Export (API)" JSON file. Logical
parameters (prompt, seed, checkpoint, ...) are mapped to nodes through a
sibling ".params.json" file, so you never hand-edit node ids.

Examples:
    # text-to-image (default transport: /run + status polling, blocks until done)
    python client/generate.py \
        --set prompt="a red fox in a snowy forest" \
        --set checkpoint=my_sdxl_model.safetensors \
        --set steps=30

    # literal /runsync (short, warm jobs only)
    python client/generate.py --runsync \
        --set prompt="a red fox" \
        --set checkpoint=my_sdxl_model.safetensors

    # image-to-video (phase 2): uploads the image, patches the LoadImage node
    python client/generate.py --workflow workflows/wan22_i2v.api.json \
        --image first_frame.png --set prompt="gentle camera pan"

Environment:
    RUNPOD_ENDPOINT_ID   Endpoint id (or pass --endpoint)
    RUNPOD_API_KEY       RunPod API key (or pass --api-key)

The default transport submits with /run and polls /status (30-minute result
retention), so long jobs - a cold worker can spend minutes staging models from
the network volume - are not cut off by HTTP connection limits. --runsync keeps
one connection open and is only reliable for short, warm jobs. Transient
failures are retried (--retries, --retry-delay); a submission whose connection
drops ambiguously is not resubmitted unless --retry-duplicate is given.

A repo-root .env file (copy .env.example) is loaded automatically; real process
environment variables take precedence. Use --env-file to point at a different
file, and --show-env to print the resolved configuration.

Model-like parameter values (checkpoint, lora, vae, ...) are checked against the
local models/manifest.json before submitting: a manifest id is not a filename,
and loader nodes need the dest basename. Use --no-model-check to skip the check.

Requires only the Python standard library (>= 3.8).
"""

from __future__ import annotations

import argparse
import base64
import difflib
import http.client
import json
import os
import random
import socket
import ssl
import sys
import time
import uuid
from datetime import datetime
from pathlib import Path
from urllib import error, request

DEFAULT_API_BASE = "https://api.runpod.ai/v2"
DEFAULT_WORKFLOW = "workflows/examples/t2i_sdxl.api.json"
FAILED_STATUSES = {"FAILED", "CANCELLED", "TIMED_OUT", "ERROR"}
MAX_SEED = 2 ** 32 - 1
DEFAULT_TIMEOUT = 1800.0
DEFAULT_SYNC_TIMEOUT = 900.0
DEFAULT_RETRIES = 3
DEFAULT_RETRY_DELAY = 2.0
MAX_RETRY_DELAY = 30.0
HTTP_RETRY_STATUSES = {429, 500, 502, 503, 504}
DEFINITE_NETWORK_ERRORS = (ConnectionRefusedError, socket.gaierror, ssl.SSLError)


class ApiError(RuntimeError):
    """Raised for endpoint/API failures so main() can exit cleanly."""


def log(message: str) -> None:
    print(f"[generate] {message}", flush=True)


def resolve_env_path(explicit: str | None) -> Path | None:
    if explicit:
        return Path(explicit)
    cwd_env = Path.cwd() / ".env"
    if cwd_env.is_file():
        return cwd_env
    repo_env = Path(__file__).resolve().parent.parent / ".env"
    return repo_env if repo_env.is_file() else None


def load_env_file(path: Path, override: bool = False) -> int:
    """Minimal .env loader: KEY=VALUE, optional `export`, # comments, quotes."""
    if not path.is_file():
        return 0
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return 0

    loaded = 0
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            continue

        name, raw = line.split("=", 1)
        name = name.strip()
        if not name or not (name[0].isalpha() or name[0] == "_"):
            continue
        if not all(ch.isalnum() or ch == "_" for ch in name):
            continue

        value = raw.strip()
        if value[:1] in ("'", '"'):
            quote = value[0]
            end = value.find(quote, 1)
            if end > 0:
                value = value[1:end]
        else:
            comment = value.find(" #")
            if comment >= 0:
                value = value[:comment].rstrip()

        if override or name not in os.environ:
            os.environ[name] = value
            loaded += 1
    return loaded


def mask_secret(value: str | None) -> str:
    if not value:
        return "(unset)"
    if len(value) <= 8:
        return "***"
    return f"{value[:4]}...{value[-4:]}"


MODEL_EXTENSIONS = (".safetensors", ".ckpt", ".pt", ".pth", ".bin")
DEFAULT_MANIFEST = os.path.join("models", "manifest.json")


def resolve_manifest_path(explicit: str | None) -> Path | None:
    if explicit:
        return Path(explicit)
    cwd_manifest = Path.cwd() / DEFAULT_MANIFEST
    if cwd_manifest.is_file():
        return cwd_manifest
    repo_manifest = Path(__file__).resolve().parent.parent / DEFAULT_MANIFEST
    return repo_manifest if repo_manifest.is_file() else None


def manifest_lookup(manifest_path: Path):
    """Map dest basenames and ids to (dest, enabled) from the local manifest."""
    try:
        manifest = load_json(manifest_path)
    except ApiError:
        return {}, {}

    by_basename = {}
    ids = {}
    for entry in manifest.get("models") or []:
        if not isinstance(entry, dict):
            continue
        dest = str(entry.get("dest") or "").strip()
        if not dest:
            continue
        enabled = entry.get("enabled", True) is not False
        by_basename[Path(dest).name] = (dest, enabled)
        entry_id = str(entry.get("id") or "").strip()
        if entry_id:
            ids[entry_id] = (dest, enabled)
    return by_basename, ids


def model_filename(value) -> str | None:
    if not isinstance(value, str):
        return None
    name = value.strip()
    if name and Path(name).suffix.lower() in MODEL_EXTENSIONS:
        return name
    return None


def validate_model_params(workflow: dict, params: dict, manifest_path: Path | None):
    """Check model-like parameter values against the local model manifest.

    Returns (errors, warnings). Errors are high-confidence mistakes (a manifest
    id used as a filename, a case mismatch, a disabled entry); warnings are
    values that are simply unknown locally (the manifest may be stale).
    """
    if manifest_path is None or not manifest_path.is_file():
        return [], []

    by_basename, ids = manifest_lookup(manifest_path)
    if not by_basename:
        return [], []

    errors = []
    warnings = []
    for key, spec in params.items():
        if not isinstance(spec, dict):
            continue
        node_id = str(spec.get("node"))
        field = str(spec.get("input"))
        node = workflow.get(node_id)
        inputs = node.get("inputs") if isinstance(node, dict) else None
        value = inputs.get(field) if isinstance(inputs, dict) else None
        name = model_filename(value)
        if name is None:
            continue

        base = Path(name).name
        if base in by_basename:
            dest, enabled = by_basename[base]
            if enabled:
                continue
            errors.append(
                f"'{base}' matches manifest entry '{dest}', which is disabled. "
                f"Enable it in models/manifest.json, deploy a release, and pre-warm."
            )
            continue

        stem = Path(base).stem
        if stem in ids:
            dest, enabled = ids[stem]
            note = "" if enabled else " (that entry is currently disabled)"
            errors.append(
                f"'{name}' (parameter '{key}') matches the manifest id '{stem}', not a file on the volume.\n"
                f"    Use the dest filename: {Path(dest).name}{note}\n"
                f"    The manifest 'id' is only a label; ComfyUI uses the 'dest' basename."
            )
            continue

        case_match = next((item for item in by_basename if item.lower() == base.lower()), None)
        if case_match:
            errors.append(
                f"'{name}' (parameter '{key}') does not match the volume filename exactly "
                f"(filenames are case-sensitive).\n    Did you mean: {case_match}"
            )
            continue

        close = difflib.get_close_matches(base, list(by_basename), n=3, cutoff=0.85)
        if close:
            errors.append(
                f"'{name}' (parameter '{key}') is not a model in the local manifest.\n"
                f"    Closest matches: {', '.join(close)}"
            )
            continue

        warnings.append(
            f"parameter '{key}' references '{name}', which is not in the local manifest "
            f"({manifest_path}); submitting anyway."
        )
    return errors, warnings


def load_json(path: Path):
    if not path.is_file():
        raise ApiError(f"file not found: {path}")
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except json.JSONDecodeError as exc:
        raise ApiError(f"invalid JSON in {path}: {exc}") from exc


def resolve_params_path(workflow_path: Path, explicit: str | None) -> Path | None:
    if explicit:
        return Path(explicit)
    name = workflow_path.name
    if name.endswith(".api.json"):
        candidate = workflow_path.with_name(name[: -len(".api.json")] + ".params.json")
    else:
        candidate = workflow_path.with_name(workflow_path.stem + ".params.json")
    return candidate if candidate.is_file() else None


def coerce_value(raw: str):
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw


def param_target(params: dict, key: str):
    if key not in params:
        available = ", ".join(sorted(params)) or "(none)"
        raise ApiError(f"unknown parameter '{key}'. Available: {available}")
    spec = params[key]
    return str(spec["node"]), str(spec["input"])


def apply_overrides(workflow: dict, params: dict, assignments, seed):
    applied = {}
    for item in assignments:
        if "=" not in item:
            raise ApiError(f"--set expects KEY=VALUE, got '{item}'")
        key, raw = item.split("=", 1)
        key = key.strip()
        node_id, field = param_target(params, key)
        if node_id not in workflow:
            raise ApiError(f"node '{node_id}' for parameter '{key}' is not in the workflow")
        workflow[node_id].setdefault("inputs", {})[field] = coerce_value(raw)
        applied[key] = workflow[node_id]["inputs"][field]

    if "seed" in params and seed is None:
        seed = random.randint(0, MAX_SEED)
        log(f"randomized seed: {seed}")
    if seed is not None:
        if "seed" not in params:
            raise ApiError("--seed was given but the params map has no 'seed' entry")
        node_id, field = param_target(params, "seed")
        workflow[node_id].setdefault("inputs", {})[field] = int(seed)
        applied["seed"] = int(seed)
    return applied


def build_images(params: dict, workflow: dict, image_paths):
    images = []
    for index, raw in enumerate(image_paths):
        path = Path(raw)
        if not path.is_file():
            raise ApiError(f"input image not found: {path}")
        key = "image" if index == 0 else f"image{index + 1}"
        if key in params:
            node_id, field = param_target(params, key)
            if node_id in workflow:
                workflow[node_id].setdefault("inputs", {})[field] = path.name
            else:
                log(f"warning: node '{node_id}' for '{key}' is not in the workflow; image not wired")
        else:
            log(f"warning: params map has no '{key}' entry; reference '{path.name}' manually in the workflow")
        images.append(
            {
                "name": path.name,
                "image": base64.b64encode(path.read_bytes()).decode("ascii"),
            }
        )
    return images


def _retry_delay(attempt: int, base: float) -> float:
    return min(MAX_RETRY_DELAY, base * (2 ** attempt)) + random.uniform(0, base)


def _classify_network_error(exc: Exception) -> str:
    """Return 'definite' (request never reached the service) or 'ambiguous'."""
    candidates = [exc]
    reason = getattr(exc, "reason", None)
    if reason is not None:
        candidates.append(reason)
    for item in candidates:
        if isinstance(item, DEFINITE_NETWORK_ERRORS):
            return "definite"
    return "ambiguous"


def http_json(url: str, payload=None, token=None, timeout=60, retries=0,
              retry_delay=DEFAULT_RETRY_DELAY, retry_ambiguous=False):
    """GET/POST JSON with retries for transient failures.

    Retries HTTP 429/5xx and pre-connection errors. Ambiguous errors (the
    request may have reached the service) are retried for GETs, but never for
    submissions unless retry_ambiguous is set - a resubmitted job runs twice.
    """
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = request.Request(url, data=data, method="POST" if data is not None else "GET")
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")

    attempt = 0
    while True:
        try:
            with request.urlopen(req, timeout=timeout) as response:
                body = response.read().decode("utf-8", "replace")
            try:
                return json.loads(body)
            except json.JSONDecodeError as exc:
                raise ApiError(f"non-JSON response from {url}: {body[:500]}") from exc
        except error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")
            if exc.code in HTTP_RETRY_STATUSES and attempt < retries:
                delay = retry_delay
                retry_after = exc.headers.get("Retry-After") if exc.headers else None
                if retry_after:
                    try:
                        delay = float(retry_after)
                    except ValueError:
                        delay = retry_delay
                delay = min(MAX_RETRY_DELAY, max(0.0, delay))
                attempt += 1
                log(f"HTTP {exc.code} from the API; retrying in {delay:.1f}s (attempt {attempt}/{retries})")
                time.sleep(delay)
                continue
            raise ApiError(f"HTTP {exc.code} from {url}: {detail[:1000]}") from exc
        except (error.URLError, http.client.HTTPException, TimeoutError, OSError) as exc:
            kind = _classify_network_error(exc)
            can_retry = kind == "definite" or payload is None or retry_ambiguous
            if can_retry and attempt < retries:
                delay = _retry_delay(attempt, retry_delay)
                attempt += 1
                log(f"network error ({exc}); retrying in {delay:.1f}s (attempt {attempt}/{retries})")
                time.sleep(delay)
                continue
            if kind == "ambiguous" and payload is not None:
                raise ApiError(
                    f"the submission connection closed before a response ({exc}).\n"
                    f"    The job may still be running - check the endpoint's Requests tab.\n"
                    f"    Prefer the default /run + status transport for jobs that take minutes;\n"
                    f"    pass --retry-duplicate if you accept that a retry may run the job twice."
                ) from exc
            reason = getattr(exc, "reason", exc)
            raise ApiError(f"request to {url} failed: {reason}") from exc


def poll_job(api_base, endpoint, token, job_id, interval, deadline,
             retries=DEFAULT_RETRIES, retry_delay=DEFAULT_RETRY_DELAY):
    status_url = f"{api_base}/{endpoint}/status/{job_id}"
    current = min(interval, 0.5)
    while True:
        response = http_json(status_url, token=token, retries=retries, retry_delay=retry_delay)
        status = response.get("status")
        if status == "COMPLETED":
            return response
        if status in FAILED_STATUSES:
            detail = response.get("error") or response.get("output") or response
            raise ApiError(f"job {job_id} ended with status {status}: {json.dumps(detail)[:1000]}")
        if time.time() >= deadline:
            raise ApiError(
                f"timed out waiting for job {job_id} (status {status}). "
                f"Poll it manually: {status_url}"
            )
        wait = max(0.2, min(interval, current))
        log(f"status={status}, waiting {wait:.1f}s...")
        time.sleep(wait)
        current = min(interval, current * 1.5)


def download_url(url: str, out_path: Path) -> None:
    try:
        with request.urlopen(url, timeout=300) as response, out_path.open("wb") as handle:
            while True:
                chunk = response.read(1024 * 512)
                if not chunk:
                    break
                handle.write(chunk)
    except (error.HTTPError, error.URLError, OSError) as exc:
        raise ApiError(f"failed to download {url}: {exc}") from exc


def save_outputs(response: dict, outdir: Path):
    output = response.get("output")
    if not isinstance(output, dict):
        raise ApiError(f"unexpected output in response: {json.dumps(response)[:1000]}")

    for warning in output.get("errors") or []:
        log(f"worker warning: {warning}")

    if output.get("error"):
        details = output.get("details") or []
        raise ApiError(f"worker error: {output['error']} {json.dumps(details)[:800]}")

    items = output.get("images") or []
    if not items:
        log("worker returned no outputs")
        return []

    outdir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")[:-3]
    saved = []
    for item in items:
        data = item.get("data") or ""
        kind = item.get("type")
        name = Path(item.get("filename") or "output").name or "output"
        out_path = outdir / f"{stamp}_{name}"

        if kind == "base64":
            if data.startswith("data:") and "," in data:
                data = data.split(",", 1)[1]
            try:
                out_path.write_bytes(base64.b64decode(data))
            except (ValueError, base64.binascii.Error) as exc:
                log(f"warning: cannot decode base64 output {name}: {exc}")
                continue
        elif kind == "s3_url":
            download_url(data, out_path)
        else:
            log(f"warning: unsupported output type '{kind}' for {name}")
            continue

        saved.append(out_path)
        log(f"saved {out_path}")
    return saved


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Run a ComfyUI API workflow on a RunPod Serverless endpoint.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--workflow", default=DEFAULT_WORKFLOW, help="API workflow JSON")
    parser.add_argument("--params", default=None, help="parameter map JSON (auto-detected next to the workflow)")
    parser.add_argument("--set", dest="assignments", action="append", default=[], metavar="KEY=VALUE",
                        help="override a mapped parameter (repeatable)")
    parser.add_argument("--seed", type=int, default=None, help="override the seed (default: random)")
    parser.add_argument("--image", dest="images", action="append", default=[], metavar="PATH",
                        help="input image to upload and wire into the workflow (repeatable)")
    parser.add_argument("--endpoint", default=None,
                        help="RunPod endpoint id (default: RUNPOD_ENDPOINT_ID)")
    parser.add_argument("--api-key", default=None,
                        help="RunPod API key (default: RUNPOD_API_KEY)")
    parser.add_argument("--api-base", default=DEFAULT_API_BASE, help="RunPod API base URL")
    parser.add_argument("--env-file", default=None,
                        help="env file to load (default: ./.env, then the repo-root .env)")
    parser.add_argument("--manifest", default=None,
                        help="model manifest for filename checks (default: ./models/manifest.json, then the repo root)")
    parser.add_argument("--no-model-check", action="store_true",
                        help="skip the model filename check against the local manifest")
    parser.add_argument("--runsync", action="store_true",
                        help="submit with the literal /runsync endpoint (short, warm jobs only; 1-minute result retention)")
    parser.add_argument("--async", dest="async_mode", action="store_true",
                        help="alias of the default /run + status transport")
    parser.add_argument("--poll-interval", type=float, default=2.0,
                        help="max seconds between status polls (starts at 0.5s and backs off)")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help="overall wait budget in seconds")
    parser.add_argument("--sync-timeout", type=float, default=DEFAULT_SYNC_TIMEOUT,
                        help="HTTP timeout for --runsync submissions")
    parser.add_argument("--retries", type=int, default=DEFAULT_RETRIES,
                        help="retries for transient HTTP/network failures")
    parser.add_argument("--retry-delay", type=float, default=DEFAULT_RETRY_DELAY,
                        help="base delay for retry backoff (exponential + jitter, capped at 30s)")
    parser.add_argument("--retry-duplicate", action="store_true",
                        help="retry a submission after an ambiguous disconnect (may run the job twice)")
    parser.add_argument("--outdir", default="out", help="directory for generated files")
    parser.add_argument("--save-json", action="store_true", help="store the raw API response next to the outputs")
    parser.add_argument("--show-params", action="store_true", help="list available parameters and exit")
    parser.add_argument("--show-env", action="store_true",
                        help="print the resolved env file, endpoint and masked API key, then exit")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)

    env_path = resolve_env_path(args.env_file)
    if env_path is not None:
        loaded = load_env_file(env_path)
        if loaded:
            log(f"loaded {loaded} variable(s) from {env_path}")

    endpoint = args.endpoint or os.environ.get("RUNPOD_ENDPOINT_ID")
    api_key = args.api_key or os.environ.get("RUNPOD_API_KEY")

    if args.show_env:
        print(f"env file: {env_path if env_path else '(none)'}")
        print(f"endpoint: {endpoint or '(unset)'}")
        print(f"api key:  {mask_secret(api_key)}")
        return 0

    workflow_path = Path(args.workflow)
    workflow = load_json(workflow_path)

    params_path = resolve_params_path(workflow_path, args.params)
    params = {}
    if params_path is not None:
        params = load_json(params_path).get("params") or {}

    if args.show_params:
        if not params:
            print("(no params map found)")
        for key in sorted(params):
            spec = params[key]
            print(f"{key} -> node {spec['node']} input '{spec['input']}'")
        return 0

    if not endpoint:
        raise ApiError("no endpoint id: pass --endpoint or set RUNPOD_ENDPOINT_ID (see .env.example)")
    if not api_key:
        raise ApiError("no API key: pass --api-key or set RUNPOD_API_KEY (see .env.example)")

    apply_overrides(workflow, params, args.assignments, args.seed)
    images = build_images(params, workflow, args.images)

    if not args.no_model_check:
        manifest_path = resolve_manifest_path(args.manifest)
        model_errors, model_warnings = validate_model_params(workflow, params, manifest_path)
        for warning in model_warnings:
            log(f"warning: {warning}")
        if model_errors:
            bullets = "\n".join(f"  - {item}" for item in model_errors)
            raise ApiError(
                "model filename check failed:\n"
                f"{bullets}\n"
                "  Use --no-model-check to bypass (for example when using a volume-local manifest)."
            )

    job_input = {"workflow": workflow}
    if images:
        job_input["images"] = images
    payload = {"input": job_input}

    deadline = time.time() + args.timeout
    job_id = str(uuid.uuid4())
    retries = max(0, args.retries)
    retry_delay = max(0.0, args.retry_delay)

    if args.runsync:
        log(f"submitting job (/runsync) to endpoint {endpoint}")
        response = http_json(
            f"{args.api_base}/{endpoint}/runsync",
            payload,
            api_key,
            timeout=max(120.0, args.sync_timeout),
            retries=retries,
            retry_delay=retry_delay,
            retry_ambiguous=args.retry_duplicate,
        )
    else:
        log(f"submitting job (/run + status polling) to endpoint {endpoint}")
        response = http_json(
            f"{args.api_base}/{endpoint}/run",
            payload,
            api_key,
            retries=retries,
            retry_delay=retry_delay,
            retry_ambiguous=args.retry_duplicate,
        )

    job_id = response.get("id") or job_id
    if response.get("status") != "COMPLETED":
        log(f"job {job_id} queued; polling for completion")
        response = poll_job(
            args.api_base, endpoint, api_key, job_id, args.poll_interval, deadline,
            retries=retries, retry_delay=retry_delay,
        )

    if args.save_json:
        outdir = Path(args.outdir)
        outdir.mkdir(parents=True, exist_ok=True)
        dump = outdir / f"{datetime.now().strftime('%Y%m%d-%H%M%S')}_{job_id}_response.json"
        dump.write_text(json.dumps(response, indent=2), encoding="utf-8")
        log(f"saved raw response to {dump}")

    saved = save_outputs(response, Path(args.outdir))
    timings = {k: response.get(k) for k in ("delayTime", "executionTime") if response.get(k) is not None}
    log(f"done: {len(saved)} file(s) saved" + (f", timings {timings}" if timings else ""))
    return 0 if saved else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ApiError as exc:
        print(f"[generate] ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print("[generate] interrupted", file=sys.stderr)
        raise SystemExit(130)
