#!/usr/bin/env bash
#
# Validate the RunPod Cached Models snapshot selected for this worker.
#
# The cached Hugging Face repository is exposed read-only at:
#   /runpod-volume/huggingface-cache/hub/models--ORG--REPO/
#
# This script never downloads or copies model files. It resolves the selected
# snapshot, checks the enabled manifest entries, and renders the ComfyUI model
# path configuration only after validation succeeds.

set -uo pipefail

log() { printf '%s [cached-models] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { log "WARN: $*"; }
err() { log "ERROR: $*" >&2; }

HF_MODEL_ID="${HF_MODEL_ID:-}"
HF_CACHE_ROOT="${HF_CACHE_ROOT:-/runpod-volume/huggingface-cache/hub}"
CONFIG_TEMPLATE="${CACHED_MODELS_CONFIG_TEMPLATE:-/etc/runpod/extra_model_paths.yaml.template}"
CONFIG_PATH="${CACHED_MODELS_CONFIG_PATH:-/comfyui/extra_model_paths.yaml}"
VERIFY_SHA="${CACHED_MODELS_VERIFY_SHA:-false}"

if [ -z "${HF_MODEL_ID}" ]; then
    warn "HF_MODEL_ID is not set; no cached Hugging Face repository was selected"
    exit 1
fi

if [[ ! "${HF_MODEL_ID}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    warn "invalid HF_MODEL_ID '${HF_MODEL_ID}'; expected an org/repository model id"
    exit 1
fi

if [ ! -f "${CONFIG_TEMPLATE}" ]; then
    err "ComfyUI model path template not found at ${CONFIG_TEMPLATE}"
    exit 1
fi

model_cache_dir="${HF_CACHE_ROOT%/}/models--${HF_MODEL_ID//\//--}"
refs_path="${model_cache_dir}/refs/main"

if [ ! -f "${refs_path}" ]; then
    warn "cached repository '${HF_MODEL_ID}' was not found at ${model_cache_dir}"
    exit 1
fi

snapshot_hash="$(tr -d '[:space:]' < "${refs_path}" | tr '[:upper:]' '[:lower:]')"
if [ -z "${snapshot_hash}" ] || [[ ! "${snapshot_hash}" =~ ^[0-9a-f]{40}$ ]]; then
    warn "cached repository '${HF_MODEL_ID}' has an invalid refs/main value"
    exit 1
fi

snapshot_root="${model_cache_dir}/snapshots/${snapshot_hash}"
if [ ! -d "${snapshot_root}" ]; then
    warn "cached snapshot '${snapshot_hash}' for '${HF_MODEL_ID}' is missing"
    exit 1
fi

manifest_path="${snapshot_root}/models/manifest.json"
if [ ! -f "${manifest_path}" ]; then
    warn "cached repository '${HF_MODEL_ID}' is missing models/manifest.json"
    exit 1
fi

PY="$(command -v python3 || command -v python || true)"
if [ -z "${PY}" ]; then
    err "no Python interpreter available to parse ${manifest_path}"
    exit 1
fi

# Manifest -> record stream. URLs and auth are intentionally ignored: cached
# models are read-only inputs and this worker must never fall back to a URL.
parse_manifest() {
    local path="$1"
    "${PY}" - "${path}" <<'PYEOF'
import json
import re
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)
except Exception as exc:  # noqa: BLE001 - report any parse problem to shell
    sys.stderr.write("invalid manifest JSON: %s\n" % exc)
    sys.exit(2)

models = manifest.get("models")
if not isinstance(models, list):
    sys.stderr.write("manifest has no 'models' list\n")
    sys.exit(2)

records = []
errors = []
for index, entry in enumerate(models):
    if not isinstance(entry, dict):
        errors.append("models[%d] is not an object" % index)
        continue
    if entry.get("enabled", True) is False:
        continue

    dest = str(entry.get("dest") or "").strip()
    parts = dest.split("/")
    if (
        not dest
        or dest.startswith(("/", "\\"))
        or "\\" in dest
        or any(part in ("", ".", "..") for part in parts)
    ):
        errors.append("models[%d] has an unsafe or empty dest: %r" % (index, dest))
        continue

    raw_size = entry.get("size_bytes")
    if raw_size in (None, ""):
        size = ""
    else:
        try:
            if isinstance(raw_size, bool):
                raise ValueError
            size_value = int(raw_size)
            if size_value < 0:
                raise ValueError
            size = str(size_value)
        except (TypeError, ValueError):
            errors.append("models[%d] has an invalid size_bytes" % index)
            continue

    sha = str(entry.get("sha256") or "").strip().lower()
    if sha.startswith("sha256:"):
        sha = sha[len("sha256:"):]
    if sha and not re.fullmatch(r"[0-9a-f]{64}", sha):
        errors.append("models[%d] has an invalid sha256" % index)
        continue

    records.append((str(entry.get("id") or dest), dest, size, sha))

if errors:
    for message in errors:
        sys.stderr.write(message + "\n")
    sys.exit(2)

if not records:
    sys.stderr.write("manifest contains no enabled model entries\n")
    sys.exit(2)

for record in records:
    sys.stdout.buffer.write(("\x1f".join(record) + "\n").encode("utf-8"))
PYEOF
}

MANIFEST_TSV="$(mktemp)"
trap 'rm -f "${MANIFEST_TSV}"' EXIT

parse_manifest "${manifest_path}" > "${MANIFEST_TSV}"
parse_rc=$?
if [ "${parse_rc}" -ne 0 ]; then
    err "failed to parse manifest at ${manifest_path}"
    exit "${parse_rc}"
fi

if [ "${VERIFY_SHA}" = "true" ] && ! command -v sha256sum >/dev/null 2>&1; then
    err "CACHED_MODELS_VERIFY_SHA=true but sha256sum is not available"
    exit 1
fi

present=0
missing=0
mismatches=0

while IFS=$'\x1f' read -r mid dest size sha; do
    dest="${dest%$'\r'}"
    [ -z "${dest:-}" ] && continue

    target="${snapshot_root}/models/${dest}"
    if [ ! -f "${target}" ]; then
        warn "MISSING ${dest} (cached repository '${HF_MODEL_ID}')"
        missing=$((missing + 1))
        continue
    fi

    actual_size="$(stat -c%s "${target}" 2>/dev/null || echo "")"
    if [ -n "${size}" ] && [ "${actual_size}" != "${size}" ]; then
        warn "SIZE ${dest} (expected ${size}, found ${actual_size})"
        mismatches=$((mismatches + 1))
        continue
    fi

    if [ "${VERIFY_SHA}" = "true" ] && [ -n "${sha}" ]; then
        actual_sha="$(sha256sum "${target}" | awk '{print $1}')"
        if [ "${actual_sha}" != "${sha}" ]; then
            warn "SHA256 ${dest} (expected ${sha}, found ${actual_sha})"
            mismatches=$((mismatches + 1))
            continue
        fi
    fi

    present=$((present + 1))
    log "present ${dest}"
done < "${MANIFEST_TSV}"

log "summary: repository=${HF_MODEL_ID} snapshot=${snapshot_hash} manifest=${manifest_path} present=${present} missing=${missing} mismatches=${mismatches}"

if [ "${missing}" -gt 0 ] || [ "${mismatches}" -gt 0 ]; then
    warn "cached model validation failed; refusing to start ComfyUI"
    exit 1
fi

config_dir="$(dirname "${CONFIG_PATH}")"
if ! mkdir -p "${config_dir}" 2>/dev/null; then
    err "could not create ComfyUI config directory ${config_dir}"
    exit 1
fi

config_tmp="$(mktemp "${CONFIG_PATH}.tmp.XXXXXX" 2>/dev/null || true)"
if [ -z "${config_tmp}" ]; then
    err "could not create temporary ComfyUI config at ${CONFIG_PATH}"
    exit 1
fi
trap 'rm -f "${MANIFEST_TSV}" "${config_tmp}"' EXIT

if ! sed "s|__CACHED_MODELS_ROOT__|${snapshot_root}|g" "${CONFIG_TEMPLATE}" > "${config_tmp}"; then
    err "could not render ComfyUI model path configuration"
    exit 1
fi

if ! mv -f "${config_tmp}" "${CONFIG_PATH}"; then
    err "could not install ComfyUI model path configuration at ${CONFIG_PATH}"
    exit 1
fi

log "ComfyUI model paths configured from ${snapshot_root}"
exit 0