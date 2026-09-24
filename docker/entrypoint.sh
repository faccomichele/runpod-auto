#!/usr/bin/env bash
#
# Entrypoint gate for the custom worker-comfyui image.
#
# Responsibilities:
#   1. Validate the RunPod Cached Models snapshot selected for the endpoint.
#   2. Configure ComfyUI to read models directly from that snapshot.
#   3. Hand off to the stock worker startup (/start.sh).
#
# Cached-model validation failures stop the worker before ComfyUI starts. This
# prevents a worker from accepting jobs when the selected repository is stale,
# incomplete, or not mounted by RunPod.
#
# Environment:
#   HF_MODEL_ID       Cached Hugging Face repository selected on the endpoint.
#   CACHED_MODELS_VERIFY_SHA
#                     "true" hashes cached files against manifest sha256 values.

set -uo pipefail

log() {
    printf '%s [entrypoint] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

VALIDATOR="${CACHED_MODELS_VALIDATOR:-/usr/local/bin/validate-cached-models.sh}"

export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1

log "cached Hugging Face model: ${HF_MODEL_ID:-<unset>}"

if [ ! -x "${VALIDATOR}" ]; then
    log "WARN: cached-model validator not found at ${VALIDATOR}"
    exit 1
fi

log "validating cached models (manifest: selected repository/models/manifest.json)"
"${VALIDATOR}"
rc=$?
if [ "${rc}" -ne 0 ]; then
    log "WARN: cached model validation failed (exit ${rc}); refusing to start worker"
    exit "${rc}"
fi

log "cached model validation completed"
log "starting worker (/start.sh)"
exec /start.sh
