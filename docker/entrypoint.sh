#!/usr/bin/env bash
#
# Entrypoint gate for the custom worker-comfyui image.
#
# Responsibilities:
#   1. Run the model bootstrap when a model storage root is mounted.
#   2. Support a "pre-warm" mode (DOWNLOAD_ONLY=true) that only downloads.
#   3. Hand off to the stock worker startup (/start.sh).
#
# Bootstrap failures do not crash the worker by default: the worker's model
# pre-flight will fail jobs with a precise "missing model" message instead of
# crash-looping the endpoint. Set BOOTSTRAP_STRICT=true to fail fast instead.
#
# Environment:
#   MODELS_ROOT       Model storage root. Serverless: /runpod-volume (default).
#                     Pods mount network volumes at /workspace (set explicitly).
#   MANIFEST_PATH     Manifest location (default /models/manifest.json).
#   MODELS_BOOTSTRAP  "false" disables the bootstrap entirely (default true).
#   DOWNLOAD_ONLY     "true" exits successfully after bootstrap (pre-warm mode).
#   BOOTSTRAP_STRICT  "true" exits non-zero when the bootstrap reports failures.
#   MODELS_VERIFY_ONLY "true" only audits the volume, downloads nothing.

set -uo pipefail

log() {
    printf '%s [entrypoint] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

MODELS_ROOT="${MODELS_ROOT:-/runpod-volume}"
MANIFEST_PATH="${MANIFEST_PATH:-/models/manifest.json}"
MODELS_BOOTSTRAP="${MODELS_BOOTSTRAP:-true}"
DOWNLOAD_ONLY="${DOWNLOAD_ONLY:-false}"
BOOTSTRAP_STRICT="${BOOTSTRAP_STRICT:-false}"
BOOTSTRAP="${BOOTSTRAP_PATH:-/usr/local/bin/bootstrap-models.sh}"

export MODELS_ROOT MANIFEST_PATH

log "model storage root: ${MODELS_ROOT}"

if [ "${MODELS_BOOTSTRAP}" = "true" ]; then
    if [ ! -x "${BOOTSTRAP}" ]; then
        log "WARN: bootstrap script not found at ${BOOTSTRAP}; skipping"
    elif [ ! -d "${MODELS_ROOT}" ]; then
        log "model storage root is not mounted; skipping bootstrap"
    else
        log "running model bootstrap (manifest: ${MANIFEST_PATH})"
        if "${BOOTSTRAP}"; then
            log "bootstrap completed"
        else
            rc=$?
            log "WARN: bootstrap reported failures (exit ${rc})"
            if [ "${DOWNLOAD_ONLY}" = "true" ] || [ "${BOOTSTRAP_STRICT}" = "true" ]; then
                log "failing fast (DOWNLOAD_ONLY/BOOTSTRAP_STRICT)"
                exit "${rc}"
            fi
            log "continuing startup; missing models will be reported by the worker pre-flight"
        fi
    fi
else
    log "MODELS_BOOTSTRAP=false; skipping bootstrap"
fi

if [ "${DOWNLOAD_ONLY}" = "true" ]; then
    log "DOWNLOAD_ONLY=true; exiting after bootstrap"
    exit 0
fi

log "starting worker (/start.sh)"
exec /start.sh
