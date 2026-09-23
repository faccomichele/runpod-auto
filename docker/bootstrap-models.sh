#!/usr/bin/env bash
#
# Idempotent model downloader for the RunPod ComfyUI worker.
#
# Reads a JSON manifest and downloads missing files onto the mounted model
# storage root (network volume), so newly started workers never re-download
# gigabytes of weights. Downloads happen on RunPod infrastructure - model data
# never travels through a local machine.
#
# Manifest entry:
#   {
#     "id":       "human-readable id",
#     "dest":     "checkpoints/model.safetensors",   # relative to <root>/models
#     "url":      "https://...",
#     "enabled":  true,                              # optional, default true
#     "size_bytes": 7130316800,                      # optional, verified if set
#     "sha256":   "hex...",                          # optional, verified if set
#     "auth":     {                                  # optional
#       "type": "query",  "param": "token", "env": "CIVITAI_TOKEN"
#       // or
#       "type": "bearer",                    "env": "HF_TOKEN"
#     }
#   }
#
# Environment:
#   MODELS_ROOT          root that contains models/ (default /runpod-volume)
#   MANIFEST_PATH        manifest path (default /models/manifest.json)
#   MODELS_VERIFY_ONLY   "true" audits only, downloads nothing
#   MODELS_VERIFY_SHA    "true" also verifies sha256 of existing files
#   MODELS_VERIFY_REQUIRE_ALL "true" exit 1 when anything is missing (audit mode)
#   BOOTSTRAP_STRICT     "true" exit 1 if any required download failed
#   BOOTSTRAP_RETRIES    download retries (default 3)
#   BOOTSTRAP_CONNECTIONS parallel connections per file (default 8)
#   BOOTSTRAP_LOCK_TIMEOUT seconds to wait for the volume lock (default 1800)

set -uo pipefail

log() { printf '%s [bootstrap] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { log "WARN: $*"; }
err() { log "ERROR: $*" >&2; }

MODELS_ROOT="${MODELS_ROOT:-/runpod-volume}"
MANIFEST_PATH="${MANIFEST_PATH:-/models/manifest.json}"
MODELS_DIR="${MODELS_ROOT}/models"

VERIFY_ONLY="${MODELS_VERIFY_ONLY:-false}"
VERIFY_SHA="${MODELS_VERIFY_SHA:-false}"
VERIFY_REQUIRE_ALL="${MODELS_VERIFY_REQUIRE_ALL:-false}"
STRICT="${BOOTSTRAP_STRICT:-false}"
RETRIES="${BOOTSTRAP_RETRIES:-3}"
CONNECTIONS="${BOOTSTRAP_CONNECTIONS:-8}"
LOCK_TIMEOUT="${BOOTSTRAP_LOCK_TIMEOUT:-1800}"

if [ ! -d "${MODELS_ROOT}" ]; then
    warn "models root '${MODELS_ROOT}' does not exist; nothing to do"
    exit 0
fi

if [ ! -f "${MANIFEST_PATH}" ]; then
    err "manifest not found at ${MANIFEST_PATH}"
    exit 1
fi

PY="$(command -v python3 || command -v python || true)"
if [ -z "${PY}" ]; then
    err "no python interpreter available to parse the manifest"
    exit 1
fi

mkdir -p "${MODELS_DIR}"/{checkpoints,unet,clip,vae,loras} 2>/dev/null || true

# ---------------------------------------------------------------------------
# Best-effort lock. flock over network filesystems is not always supported,
# so a failure to lock is logged but never fatal.
# ---------------------------------------------------------------------------
if command -v flock >/dev/null 2>&1; then
    if exec 9>"${MODELS_DIR}/.bootstrap.lock" 2>/dev/null; then
        if ! flock -w "${LOCK_TIMEOUT}" 9; then
            warn "could not acquire bootstrap lock within ${LOCK_TIMEOUT}s; proceeding"
        fi
    else
        warn "could not open bootstrap lock file; proceeding without lock"
    fi
fi

# ---------------------------------------------------------------------------
# Manifest -> record stream (ASCII unit separator, so empty fields survive)
# Fields: id, dest, url, size, sha256, auth_type, auth_param, auth_env
# ---------------------------------------------------------------------------
parse_manifest() {
    "${PY}" - "${MANIFEST_PATH}" <<'PYEOF'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)
except Exception as exc:  # noqa: BLE001 - report any parse problem to the shell
    sys.stderr.write("invalid manifest JSON: %s\n" % exc)
    sys.exit(2)

models = manifest.get("models")
if not isinstance(models, list):
    sys.stderr.write("manifest has no 'models' list\n")
    sys.exit(2)

for entry in models:
    if not isinstance(entry, dict) or entry.get("enabled", True) is False:
        continue
    dest = str(entry.get("dest") or "").strip()
    url = str(entry.get("url") or "").strip()
    if not dest or not url:
        continue
    size = entry.get("size_bytes")
    size = "" if size in (None, "") else str(int(size))
    sha = str(entry.get("sha256") or "").strip().lower()
    if sha.startswith("sha256:"):
        sha = sha[len("sha256:"):]
    auth = entry.get("auth") or {}
    if not isinstance(auth, dict):
        auth = {}
    fields = [
        str(entry.get("id") or dest),
        dest,
        url,
        size,
        sha,
        str(auth.get("type") or ""),
        str(auth.get("param") or "token"),
        str(auth.get("env") or ""),
    ]
    # Write bytes directly: text-mode stdout on Windows would turn \n into \r\n.
    sys.stdout.buffer.write(("\x1f".join(fields) + "\n").encode("utf-8"))
PYEOF
}

MANIFEST_TSV="$(mktemp)"
trap 'rm -f "${MANIFEST_TSV}"' EXIT

if ! parse_manifest > "${MANIFEST_TSV}"; then
    err "failed to parse manifest at ${MANIFEST_PATH}"
    exit 1
fi

ENTRY_COUNT="$(wc -l < "${MANIFEST_TSV}" | tr -d ' ')"
if [ "${ENTRY_COUNT}" = "0" ]; then
    warn "manifest contains no enabled model entries"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
append_query() { # url param value
    case "$1" in
        *\?*) printf '%s&%s=%s' "$1" "$2" "$3" ;;
        *)    printf '%s?%s=%s' "$1" "$2" "$3" ;;
    esac
}

hash_file() { sha256sum "$1" | awk '{print $1}'; }

download_one() { # url part_path [extra args...]
    local url="$1"
    local part="$2"
    shift 2
    if command -v aria2c >/dev/null 2>&1; then
        aria2c \
            --continue=true \
            --auto-file-renaming=false \
            --allow-overwrite=true \
            --file-allocation=none \
            --max-connection-per-server="${CONNECTIONS}" \
            --split="${CONNECTIONS}" \
            --min-split-size=1M \
            --max-tries="${RETRIES}" \
            --retry-wait=5 \
            --console-log-level=warn \
            --summary-interval=30 \
            --dir="$(dirname "${part}")" \
            --out="$(basename "${part}")" \
            "$@" \
            "${url}"
    elif command -v curl >/dev/null 2>&1; then
        curl --fail --location --retry "${RETRIES}" --retry-delay 5 \
            --output "${part}" "$@" "${url}"
    else
        wget --continue --tries="${RETRIES}" --waitretry=5 -O "${part}" "$@" "${url}"
    fi
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
downloaded=0
present=0
missing=0
failures=0

while IFS=$'\x1f' read -r mid dest url size sha atype aparam aenv; do
    aenv="${aenv%$'\r'}"
    [ -z "${dest:-}" ] && continue

    target="${MODELS_DIR}/${dest}"
    mkdir -p "$(dirname "${target}")"

    exists=false
    [ -f "${target}" ] && exists=true
    actual_size=""
    if [ "${exists}" = "true" ]; then
        actual_size="$(stat -c%s "${target}" 2>/dev/null || echo "")"
    fi

    # ---- audit-only mode ---------------------------------------------------
    if [ "${VERIFY_ONLY}" = "true" ]; then
        if [ "${exists}" != "true" ]; then
            warn "MISSING  ${dest}"
            missing=$((missing + 1))
            continue
        fi
        if [ -n "${size}" ] && [ "${actual_size}" != "${size}" ]; then
            warn "SIZE     ${dest} (expected ${size}, found ${actual_size})"
            missing=$((missing + 1))
            continue
        fi
        if [ -n "${sha}" ] && [ "${VERIFY_SHA}" = "true" ]; then
            actual_sha="$(hash_file "${target}")"
            if [ "${actual_sha}" != "${sha}" ]; then
                warn "SHA256   ${dest} (expected ${sha}, found ${actual_sha})"
                missing=$((missing + 1))
                continue
            fi
        fi
        log "OK       ${dest}"
        continue
    fi

    # ---- already present ---------------------------------------------------
    if [ "${exists}" = "true" ]; then
        if [ -z "${size}" ] || [ "${actual_size}" = "${size}" ]; then
            present=$((present + 1))
            log "present  ${dest}"
            continue
        fi
        warn "size mismatch for ${dest} (expected ${size}, found ${actual_size}); re-downloading"
    fi

    # ---- auth --------------------------------------------------------------
    extra=()
    final_url="${url}"
    token=""
    if [ -n "${aenv}" ]; then
        token="${!aenv:-}"
    fi

    if [ "${atype}" = "bearer" ]; then
        if [ -n "${token}" ]; then
            extra+=(--header="Authorization: Bearer ${token}")
        else
            warn "env ${aenv} is not set; trying ${dest} without auth"
        fi
    elif [ "${atype}" = "query" ]; then
        if [ -n "${token}" ]; then
            final_url="$(append_query "${url}" "${aparam:-token}" "${token}")"
        else
            warn "env ${aenv} is not set; trying ${dest} without auth token"
        fi
    fi

    # ---- download ----------------------------------------------------------
    part="${target}.part"
    log "downloading ${dest}"
    if ! download_one "${final_url}" "${part}" "${extra[@]}"; then
        err "download failed for ${dest}"
        failures=$((failures + 1))
        continue
    fi

    downloaded_size="$(stat -c%s "${part}" 2>/dev/null || echo "")"
    if [ -n "${size}" ] && [ "${downloaded_size}" != "${size}" ]; then
        err "size mismatch after download for ${dest} (expected ${size}, found ${downloaded_size})"
        failures=$((failures + 1))
        rm -f "${part}"
        continue
    fi

    if [ -n "${sha}" ]; then
        actual_sha="$(hash_file "${part}")"
        if [ "${actual_sha}" != "${sha}" ]; then
            err "sha256 mismatch for ${dest} (expected ${sha}, found ${actual_sha})"
            failures=$((failures + 1))
            rm -f "${part}"
            continue
        fi
    fi

    mv -f "${part}" "${target}"
    downloaded=$((downloaded + 1))
    if command -v numfmt >/dev/null 2>&1; then
        log "installed ${dest} ($(numfmt --to=iec "${downloaded_size}" 2>/dev/null || echo "${downloaded_size} bytes"))"
    else
        log "installed ${dest} (${downloaded_size} bytes)"
    fi
done < "${MANIFEST_TSV}"

log "summary: downloaded=${downloaded} present=${present} missing=${missing} failures=${failures}"

if command -v df >/dev/null 2>&1; then
    df -h "${MODELS_ROOT}" 2>/dev/null | sed 's/^/[bootstrap] /' || true
fi

if [ "${VERIFY_ONLY}" = "true" ]; then
    if [ "${missing}" -gt 0 ] && [ "${VERIFY_REQUIRE_ALL}" = "true" ]; then
        exit 1
    fi
    exit 0
fi

if [ "${failures}" -gt 0 ]; then
    exit 1
fi

exit 0
