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

EXIT_CONFIG=10
EXIT_CACHE=20
EXIT_SNAPSHOT=30
EXIT_MANIFEST=40
EXIT_MODELS=50
EXIT_RENDER=60
DIAGNOSTIC_LIMIT=40

log() { printf '%s [cached-models] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { log "WARN: $*"; }
err() { log "ERROR: $*" >&2; }

model_cache_dir=""
refs_path=""
snapshot_hash=""
snapshot_root=""
manifest_path=""

fail() {
    local exit_code="$1"
    local failure_code="$2"
    local reason="$3"
    log "FAIL code=${failure_code} exit=${exit_code} reason=${reason} repository=${HF_MODEL_ID:-<unset>} cache_root=${HF_CACHE_ROOT:-<unset>} model_cache_dir=${model_cache_dir:-<unset>} refs_path=${refs_path:-<unset>} snapshot_hash=${snapshot_hash:-<unset>} snapshot_root=${snapshot_root:-<unset>} manifest_path=${manifest_path:-<unset>}"
    exit "${exit_code}"
}

list_directory() {
    local label="$1"
    local path="$2"
    local count
    local item

    if [ ! -e "${path}" ]; then
        log "diagnostic ${label}=missing path=${path}"
        return
    fi
    if [ ! -d "${path}" ]; then
        log "diagnostic ${label}=not_directory path=${path}"
        return
    fi

    count="$(find "${path}" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | wc -l | tr -d '[:space:]')"
    log "diagnostic ${label}=directory path=${path} entries=${count:-unknown}"
    while IFS= read -r item; do
        [ -n "${item}" ] && log "diagnostic ${label}_item=${item}"
    done < <(find "${path}" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort | head -n "${DIAGNOSTIC_LIMIT}")

    case "${count}" in
        ''|*[!0-9]*) ;;
        *)
            if [ "${count}" -gt "${DIAGNOSTIC_LIMIT}" ]; then
                log "diagnostic ${label}=truncated limit=${DIAGNOSTIC_LIMIT}"
            fi
            ;;
    esac
}

HF_MODEL_ID="${HF_MODEL_ID:-}"
HF_CACHE_ROOT="${HF_CACHE_ROOT:-/runpod-volume/huggingface-cache/hub}"
CONFIG_TEMPLATE="${CACHED_MODELS_CONFIG_TEMPLATE:-/etc/runpod/extra_model_paths.yaml.template}"
CONFIG_PATH="${CACHED_MODELS_CONFIG_PATH:-/comfyui/extra_model_paths.yaml}"
VERIFY_SHA="${CACHED_MODELS_VERIFY_SHA:-false}"

if [ -z "${HF_MODEL_ID}" ]; then
    fail "${EXIT_CONFIG}" "CACHED_MODELS_CONFIG_MISSING" "HF_MODEL_ID_not_set"
fi

if [[ ! "${HF_MODEL_ID}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    fail "${EXIT_CONFIG}" "CACHED_MODELS_CONFIG_INVALID" "HF_MODEL_ID_must_be_org_repository"
fi

if [ ! -f "${CONFIG_TEMPLATE}" ]; then
    fail "${EXIT_CONFIG}" "CACHED_MODELS_CONFIG_MISSING" "config_template_not_found"
fi

case "${VERIFY_SHA}" in
    true|false) ;;
    *)
        fail "${EXIT_CONFIG}" "CACHED_MODELS_CONFIG_INVALID" "CACHED_MODELS_VERIFY_SHA_must_be_true_or_false"
        ;;
esac

if [ ! -d "${HF_CACHE_ROOT}" ]; then
    fail "${EXIT_CACHE}" "CACHED_MODELS_CACHE_ROOT_MISSING" "cache_root_not_found"
fi

model_cache_dir="${HF_CACHE_ROOT%/}/models--${HF_MODEL_ID//\//--}"
refs_path="${model_cache_dir}/refs/main"

if [ ! -f "${refs_path}" ]; then
    list_directory "cache_root" "${HF_CACHE_ROOT}"
    fail "${EXIT_CACHE}" "CACHED_MODELS_REPOSITORY_MISSING" "refs_main_not_found"
fi

snapshot_hash="$(tr -d '[:space:]' < "${refs_path}" | tr '[:upper:]' '[:lower:]')"
if [ -z "${snapshot_hash}" ] || [[ ! "${snapshot_hash}" =~ ^[0-9a-f]{40}$ ]]; then
    list_directory "model_cache" "${model_cache_dir}"
    fail "${EXIT_SNAPSHOT}" "CACHED_MODELS_SNAPSHOT_INVALID" "refs_main_must_be_40_hex_characters"
fi

snapshot_root="${model_cache_dir}/snapshots/${snapshot_hash}"
if [ ! -d "${snapshot_root}" ]; then
    list_directory "snapshots" "${model_cache_dir}/snapshots"
    fail "${EXIT_SNAPSHOT}" "CACHED_MODELS_SNAPSHOT_MISSING" "snapshot_directory_not_found"
fi

manifest_path="${snapshot_root}/manifest.json"
if [ ! -f "${manifest_path}" ]; then
    list_directory "snapshot_root" "${snapshot_root}"
    fail "${EXIT_MANIFEST}" "CACHED_MODELS_MANIFEST_MISSING" "root_manifest_not_found"
fi

PY="$(command -v python3 || command -v python || true)"
if [ -z "${PY}" ]; then
    fail "${EXIT_CONFIG}" "CACHED_MODELS_RUNTIME_MISSING" "python_interpreter_not_found"
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

MANIFEST_TSV="$(mktemp 2>/dev/null || true)"
if [ -z "${MANIFEST_TSV}" ]; then
    fail "${EXIT_RENDER}" "CACHED_MODELS_OUTPUT_FAILED" "manifest_temp_file_creation_failed"
fi
config_tmp=""
cleanup() {
    [ -z "${MANIFEST_TSV}" ] || rm -f "${MANIFEST_TSV}"
    [ -z "${config_tmp}" ] || rm -f "${config_tmp}"
}
trap cleanup EXIT

parse_manifest "${manifest_path}" > "${MANIFEST_TSV}"
parse_rc=$?
if [ "${parse_rc}" -ne 0 ]; then
    fail "${EXIT_MANIFEST}" "CACHED_MODELS_MANIFEST_INVALID" "manifest_parse_failed"
fi

if [ "${VERIFY_SHA}" = "true" ] && ! command -v sha256sum >/dev/null 2>&1; then
    fail "${EXIT_CONFIG}" "CACHED_MODELS_RUNTIME_MISSING" "sha256sum_not_found"
fi

present=0
missing=0
mismatches=0

while IFS=$'\x1f' read -r mid dest size sha; do
    dest="${dest%$'\r'}"
    [ -z "${dest:-}" ] && continue

    target="${snapshot_root}/${dest}"
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
    fail "${EXIT_MODELS}" "CACHED_MODELS_MODEL_MISMATCH" "enabled_model_validation_failed"
fi

config_dir="$(dirname "${CONFIG_PATH}")"
if ! mkdir -p "${config_dir}" 2>/dev/null; then
    fail "${EXIT_RENDER}" "CACHED_MODELS_OUTPUT_FAILED" "config_directory_creation_failed"
fi

config_tmp="$(mktemp "${CONFIG_PATH}.tmp.XXXXXX" 2>/dev/null || true)"
if [ -z "${config_tmp}" ]; then
    fail "${EXIT_RENDER}" "CACHED_MODELS_OUTPUT_FAILED" "config_temp_file_creation_failed"
fi

if ! sed "s|__CACHED_MODELS_ROOT__|${snapshot_root}|g" "${CONFIG_TEMPLATE}" > "${config_tmp}"; then
    fail "${EXIT_RENDER}" "CACHED_MODELS_OUTPUT_FAILED" "config_render_failed"
fi

if ! mv -f "${config_tmp}" "${CONFIG_PATH}"; then
    fail "${EXIT_RENDER}" "CACHED_MODELS_OUTPUT_FAILED" "config_install_failed"
fi

log "ComfyUI model paths configured from ${snapshot_root}"
exit 0