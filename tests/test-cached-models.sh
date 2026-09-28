#!/usr/bin/env bash

set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
validator="${script_dir}/../docker/validate-cached-models.sh"
test_root="$(mktemp -d)"

cleanup() {
    rm -rf "${test_root}"
}
trap cleanup EXIT

snapshot_hash="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

make_case() {
    local name="$1"
    local case_root="${test_root}/${name}"
    local snapshot_root="${case_root}/cache/models--org--repo/snapshots/${snapshot_hash}"

    mkdir -p "${case_root}/cache/models--org--repo/refs" "${snapshot_root}/checkpoints"
    printf '%s' "${snapshot_hash}" > "${case_root}/cache/models--org--repo/refs/main"
    printf '%s' 'fixture-model' > "${snapshot_root}/checkpoints/example.safetensors"
    printf '%s\n' 'base_path: __CACHED_MODELS_ROOT__' > "${case_root}/template.yaml"
}

write_manifest() {
    local case_root="$1"
    local size="$(wc -c < "${case_root}/cache/models--org--repo/snapshots/${snapshot_hash}/checkpoints/example.safetensors" | tr -d '[:space:]')"
    local sha="$(sha256sum "${case_root}/cache/models--org--repo/snapshots/${snapshot_hash}/checkpoints/example.safetensors" | awk '{print $1}')"

    printf '{"models":[{"id":"fixture","dest":"checkpoints/example.safetensors","size_bytes":%s,"sha256":"%s"}]}\n' \
        "${size}" "${sha}" > "${case_root}/cache/models--org--repo/snapshots/${snapshot_hash}/manifest.json"
}

run_validator() {
    local case_root="$1"
    local model_id="$2"
    local verify_sha="${3:-false}"
    local fetch_manifest="${4:-false}"
    local token="${5:-}"
    local remote_url="${6:-}"
    local config_path="${case_root}/rendered.yaml"
    local -a validator_env=(
        "HF_CACHE_ROOT=${case_root}/cache"
        "CACHED_MODELS_VERIFY_SHA=${verify_sha}"
        "CACHED_MODELS_CONFIG_TEMPLATE=${case_root}/template.yaml"
        "CACHED_MODELS_CONFIG_PATH=${config_path}"
        "CACHED_MODELS_FETCH_FRESH_MANIFEST=${fetch_manifest}"
        "HF_TOKEN=${token}"
        "CACHED_MODELS_REMOTE_MANIFEST_URL=${remote_url}"
    )

    if [ "${model_id}" = "__unset__" ]; then
        CASE_OUTPUT="$(env -u HF_MODEL_ID "${validator_env[@]}" bash "${validator}" 2>&1)"
    else
        CASE_OUTPUT="$(env "${validator_env[@]}" "HF_MODEL_ID=${model_id}" bash "${validator}" 2>&1)"
    fi
    CASE_STATUS=$?
}

assert_case() {
    local name="$1"
    local expected_status="$2"
    local expected_code="$3"

    if [ "${CASE_STATUS}" -ne "${expected_status}" ]; then
        printf 'FAIL %s: expected exit %s, got %s\n%s\n' \
            "${name}" "${expected_status}" "${CASE_STATUS}" "${CASE_OUTPUT}" >&2
        exit 1
    fi
    if [[ "${CASE_OUTPUT}" != *"code=${expected_code}"* ]]; then
        printf 'FAIL %s: missing code %s\n%s\n' \
            "${name}" "${expected_code}" "${CASE_OUTPUT}" >&2
        exit 1
    fi
    printf 'PASS %s (exit %s, %s)\n' "${name}" "${CASE_STATUS}" "${expected_code}"
}

make_case missing_hf_model
run_validator "${test_root}/missing_hf_model" __unset__
assert_case missing_hf_model 10 CACHED_MODELS_CONFIG_MISSING

make_case invalid_hf_model
run_validator "${test_root}/invalid_hf_model" bad
assert_case invalid_hf_model 10 CACHED_MODELS_CONFIG_INVALID

make_case missing_cache_root
rm -rf "${test_root}/missing_cache_root/cache"
run_validator "${test_root}/missing_cache_root" org/repo
assert_case missing_cache_root 20 CACHED_MODELS_CACHE_ROOT_MISSING

make_case missing_repository
rm -rf "${test_root}/missing_repository/cache/models--org--repo"
run_validator "${test_root}/missing_repository" org/repo
assert_case missing_repository 20 CACHED_MODELS_REPOSITORY_MISSING
[[ "${CASE_OUTPUT}" == *"diagnostic cache_root="* ]] || exit 1

make_case invalid_snapshot_ref
printf '%s' 'invalid' > "${test_root}/invalid_snapshot_ref/cache/models--org--repo/refs/main"
run_validator "${test_root}/invalid_snapshot_ref" org/repo
assert_case invalid_snapshot_ref 30 CACHED_MODELS_SNAPSHOT_INVALID

make_case missing_snapshot
rm -rf "${test_root}/missing_snapshot/cache/models--org--repo/snapshots/${snapshot_hash}"
run_validator "${test_root}/missing_snapshot" org/repo
assert_case missing_snapshot 30 CACHED_MODELS_SNAPSHOT_MISSING

make_case missing_manifest
for index in $(seq 1 50); do
    printf '%s' 'fixture' > "${test_root}/missing_manifest/cache/models--org--repo/snapshots/${snapshot_hash}/entry-${index}"
done
run_validator "${test_root}/missing_manifest" org/repo
assert_case missing_manifest 40 CACHED_MODELS_MANIFEST_MISSING
[[ "${CASE_OUTPUT}" == *"diagnostic snapshot_root_item=checkpoints"* ]] || exit 1
item_count="$(printf '%s\n' "${CASE_OUTPUT}" | grep -c 'diagnostic snapshot_root_item=' || true)"
[ "${item_count}" -le 40 ] || exit 1
[[ "${CASE_OUTPUT}" == *"diagnostic snapshot_root=truncated limit=40"* ]] || exit 1

make_case malformed_manifest
printf '%s' 'not-json' > "${test_root}/malformed_manifest/cache/models--org--repo/snapshots/${snapshot_hash}/manifest.json"
run_validator "${test_root}/malformed_manifest" org/repo
assert_case malformed_manifest 40 CACHED_MODELS_MANIFEST_INVALID

make_case missing_file
printf '%s' '{"models":[{"dest":"checkpoints/missing.safetensors","size_bytes":13}]}' > \
    "${test_root}/missing_file/cache/models--org--repo/snapshots/${snapshot_hash}/manifest.json"
run_validator "${test_root}/missing_file" org/repo
assert_case missing_file 50 CACHED_MODELS_MODEL_MISMATCH

make_case size_mismatch
printf '%s' '{"models":[{"dest":"checkpoints/example.safetensors","size_bytes":14}]}' > \
    "${test_root}/size_mismatch/cache/models--org--repo/snapshots/${snapshot_hash}/manifest.json"
run_validator "${test_root}/size_mismatch" org/repo
assert_case size_mismatch 50 CACHED_MODELS_MODEL_MISMATCH

make_case sha_mismatch
printf '%s' '{"models":[{"dest":"checkpoints/example.safetensors","size_bytes":13,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}]}' > \
    "${test_root}/sha_mismatch/cache/models--org--repo/snapshots/${snapshot_hash}/manifest.json"
run_validator "${test_root}/sha_mismatch" org/repo true
assert_case sha_mismatch 50 CACHED_MODELS_MODEL_MISMATCH

make_case fallback_disabled
run_validator "${test_root}/fallback_disabled" org/repo false false unused-token \
    "file://${test_root}/fallback_disabled/does-not-exist.json"
assert_case fallback_disabled 40 CACHED_MODELS_MANIFEST_MISSING
[[ "${CASE_OUTPUT}" != *"remote manifest"* ]] || exit 1

make_case fallback_without_token
run_validator "${test_root}/fallback_without_token" org/repo false true "" \
    "file://${test_root}/fallback_without_token/does-not-exist.json"
assert_case fallback_without_token 10 CACHED_MODELS_REMOTE_MANIFEST_TOKEN_MISSING

make_case fallback_invalid_url
run_validator "${test_root}/fallback_invalid_url" org/repo false true secret-token \
    "https://example.invalid/manifest.json"
assert_case fallback_invalid_url 10 CACHED_MODELS_CONFIG_INVALID
[[ "${CASE_OUTPUT}" != *"secret-token"* ]] || exit 1

make_case fallback_missing_cached_manifest
write_manifest "${test_root}/fallback_missing_cached_manifest"
cp "${test_root}/fallback_missing_cached_manifest/cache/models--org--repo/snapshots/${snapshot_hash}/manifest.json" \
    "${test_root}/fallback_missing_cached_manifest/remote-manifest.json"
rm "${test_root}/fallback_missing_cached_manifest/cache/models--org--repo/snapshots/${snapshot_hash}/manifest.json"
run_validator "${test_root}/fallback_missing_cached_manifest" org/repo false true secret-token \
    "file://${test_root}/fallback_missing_cached_manifest/remote-manifest.json"
assert_case fallback_missing_cached_manifest 40 CACHED_MODELS_MANIFEST_MISSING
[[ "${CASE_OUTPUT}" == *"remote manifest fetched source=repository_main metadata_only=true"* ]] || exit 1
[[ "${CASE_OUTPUT}" != *"secret-token"* ]] || exit 1

make_case fallback_matching_manifest
write_manifest "${test_root}/fallback_matching_manifest"
cp "${test_root}/fallback_matching_manifest/cache/models--org--repo/snapshots/${snapshot_hash}/manifest.json" \
    "${test_root}/fallback_matching_manifest/remote-manifest.json"
run_validator "${test_root}/fallback_matching_manifest" org/repo true true secret-token \
    "file://${test_root}/fallback_matching_manifest/remote-manifest.json"
if [ "${CASE_STATUS}" -ne 0 ]; then
    printf 'FAIL fallback_matching_manifest: expected exit 0, got %s\n%s\n' \
        "${CASE_STATUS}" "${CASE_OUTPUT}" >&2
    exit 1
fi
[[ "${CASE_OUTPUT}" == *"remote_manifest_comparison=match"* ]] || exit 1
[[ "${CASE_OUTPUT}" != *"secret-token"* ]] || exit 1
printf 'PASS fallback_matching_manifest (exit 0)\n'

make_case fallback_stale_manifest
write_manifest "${test_root}/fallback_stale_manifest"
printf '%s' '{"models":[{"id":"new-entry","dest":"text_encoders/qwen_3_4b.safetensors","size_bytes":13}]}' > \
    "${test_root}/fallback_stale_manifest/remote-manifest.json"
run_validator "${test_root}/fallback_stale_manifest" org/repo false true secret-token \
    "file://${test_root}/fallback_stale_manifest/remote-manifest.json"
assert_case fallback_stale_manifest 40 CACHED_MODELS_MANIFEST_STALE
[[ "${CASE_OUTPUT}" == *"remote_manifest_comparison=mismatch"* ]] || exit 1
[[ "${CASE_OUTPUT}" != *"secret-token"* ]] || exit 1

make_case fallback_fetch_failure
run_validator "${test_root}/fallback_fetch_failure" org/repo false true secret-token \
    "file://${test_root}/fallback_fetch_failure/does-not-exist.json"
assert_case fallback_fetch_failure 40 CACHED_MODELS_REMOTE_MANIFEST_FETCH_FAILED
[[ "${CASE_OUTPUT}" != *"secret-token"* ]] || exit 1

make_case fallback_does_not_repair_missing_file
write_manifest "${test_root}/fallback_does_not_repair_missing_file"
cp "${test_root}/fallback_does_not_repair_missing_file/cache/models--org--repo/snapshots/${snapshot_hash}/manifest.json" \
    "${test_root}/fallback_does_not_repair_missing_file/remote-manifest.json"
rm "${test_root}/fallback_does_not_repair_missing_file/cache/models--org--repo/snapshots/${snapshot_hash}/checkpoints/example.safetensors"
run_validator "${test_root}/fallback_does_not_repair_missing_file" org/repo false true secret-token \
    "file://${test_root}/fallback_does_not_repair_missing_file/remote-manifest.json"
assert_case fallback_does_not_repair_missing_file 50 CACHED_MODELS_MODEL_MISMATCH
[[ "${CASE_OUTPUT}" == *"remote_manifest_comparison=match"* ]] || exit 1

make_case valid
write_manifest "${test_root}/valid"
run_validator "${test_root}/valid" org/repo true
if [ "${CASE_STATUS}" -ne 0 ]; then
    printf 'FAIL valid: expected exit 0, got %s\n%s\n' "${CASE_STATUS}" "${CASE_OUTPUT}" >&2
    exit 1
fi
grep -Fq "base_path: ${test_root}/valid/cache/models--org--repo/snapshots/${snapshot_hash}" \
    "${test_root}/valid/rendered.yaml" || exit 1
printf 'PASS valid (exit 0)\n'