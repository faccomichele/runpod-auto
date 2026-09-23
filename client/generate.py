#!/usr/bin/env python3
"""Submit ComfyUI API workflows to a RunPod Serverless endpoint and save results.

The workflow is a ComfyUI "Workflow > Export (API)" JSON file. Logical
parameters (prompt, seed, checkpoint, ...) are mapped to nodes through a
sibling ".params.json" file, so you never hand-edit node ids.

Examples:
    # text-to-image (sync; waits for the result)
    python client/generate.py \
        --set prompt="a red fox in a snowy forest" \
        --set checkpoint=my_sdxl_model.safetensors \
        --set steps=30

    # async (recommended for long jobs / video later)
    python client/generate.py --async \
        --set prompt="a red fox" \
        --set checkpoint=my_sdxl_model.safetensors

    # image-to-video (phase 2): uploads the image, patches the LoadImage node
    python client/generate.py --workflow workflows/wan22_i2v.api.json \
        --image first_frame.png --set prompt="gentle camera pan"

Environment:
    RUNPOD_ENDPOINT_ID   Endpoint id (or pass --endpoint)
    RUNPOD_API_KEY       RunPod API key (or pass --api-key)

A repo-root .env file (copy .env.example) is loaded automatically; real process
environment variables take precedence. Use --env-file to point at a different
file, and --show-env to print the resolved configuration.

Requires only the Python standard library (>= 3.8).
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import random
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


def http_json(url: str, payload=None, token=None, timeout=60):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = request.Request(url, data=data, method="POST" if data is not None else "GET")
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with request.urlopen(req, timeout=timeout) as response:
            body = response.read().decode("utf-8", "replace")
    except error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise ApiError(f"HTTP {exc.code} from {url}: {detail[:1000]}") from exc
    except error.URLError as exc:
        raise ApiError(f"request to {url} failed: {exc.reason}") from exc
    try:
        return json.loads(body)
    except json.JSONDecodeError as exc:
        raise ApiError(f"non-JSON response from {url}: {body[:500]}") from exc


def poll_job(api_base, endpoint, token, job_id, interval, deadline):
    status_url = f"{api_base}/{endpoint}/status/{job_id}"
    while True:
        response = http_json(status_url, token=token)
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
        log(f"status={status}, waiting {interval:.0f}s...")
        time.sleep(interval)


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
    parser.add_argument("--async", dest="async_mode", action="store_true",
                        help="submit with /run and poll /status (best for long jobs/video)")
    parser.add_argument("--poll-interval", type=float, default=2.0, help="seconds between status polls")
    parser.add_argument("--timeout", type=float, default=900.0, help="overall wait budget in seconds")
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

    job_input = {"workflow": workflow}
    if images:
        job_input["images"] = images
    payload = {"input": job_input}

    deadline = time.time() + args.timeout
    job_id = str(uuid.uuid4())

    if args.async_mode:
        log(f"submitting job (async) to endpoint {endpoint}")
        response = http_json(f"{args.api_base}/{endpoint}/run", payload, api_key)
    else:
        log(f"submitting job (sync) to endpoint {endpoint}")
        response = http_json(
            f"{args.api_base}/{endpoint}/runsync",
            payload,
            api_key,
            timeout=max(120.0, args.timeout),
        )

    job_id = response.get("id") or job_id
    if response.get("status") != "COMPLETED":
        log(f"job {job_id} queued; polling for completion")
        response = poll_job(args.api_base, endpoint, api_key, job_id, args.poll_interval, deadline)

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
