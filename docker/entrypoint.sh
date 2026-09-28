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
#   CACHED_MODELS_FETCH_FRESH_MANIFEST
#                     "true" fetches only the private repository's root
#                     manifest for stale-cache diagnostics; it requires a
#                     separately injected HF_TOKEN and never downloads models.

set -uo pipefail

# Keep early validation errors in the same stream as the worker logs.
exec 2>&1

log() {
    printf '%s [entrypoint] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

VALIDATOR="${CACHED_MODELS_VALIDATOR:-/usr/local/bin/validate-cached-models.sh}"
startup_stage="initialization"

fail_startup() {
    local exit_code="$1"
    local failure_code="$2"
    local reason="$3"
    log "FAIL code=${failure_code} exit=${exit_code} stage=${startup_stage} reason=${reason} repository=${HF_MODEL_ID:-<unset>} validator=${VALIDATOR} action=refusing_to_start"
    exit "${exit_code}"
}

report_failure() {
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        log "ERROR: startup_failed stage=${startup_stage} exit=${rc} repository=${HF_MODEL_ID:-<unset>} action=container_will_exit"
    fi
}

trap report_failure EXIT

export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1

log "cached Hugging Face model: ${HF_MODEL_ID:-<unset>}"

if [ ! -x "${VALIDATOR}" ]; then
    startup_stage="validator check"
    fail_startup 70 "ENTRYPOINT_VALIDATOR_MISSING" "validator_not_executable"
fi

startup_stage="cached model validation"
log "validating cached models (manifest: selected repository/manifest.json)"
"${VALIDATOR}"
rc=$?
if [ "${rc}" -ne 0 ]; then
    log "FAIL code=CACHED_MODELS_VALIDATION_FAILED exit=${rc} stage=${startup_stage} repository=${HF_MODEL_ID:-<unset>} validator=${VALIDATOR} action=refusing_to_start details=see_cached_models_failure_record"
    exit "${rc}"
fi

startup_stage="worker handoff"
log "cached model validation completed"
log "starting worker (/start.sh)"
exec /start.sh
