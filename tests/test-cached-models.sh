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
    local config_path="${case_root}/rendered.yaml"

    if [ "${model_id}" = "__unset__" ]; then
        CASE_OUTPUT="$(env -u HF_MODEL_ID \
            HF_CACHE_ROOT="${case_root}/cache" \
            CACHED_MODELS_VERIFY_SHA="${verify_sha}" \
            CACHED_MODELS_CONFIG_TEMPLATE="${case_root}/template.yaml" \
            CACHED_MODELS_CONFIG_PATH="${config_path}" \
            bash "${validator}" 2>&1)"
    else
        CASE_OUTPUT="$(HF_MODEL_ID="${model_id}" \
            HF_CACHE_ROOT="${case_root}/cache" \
            CACHED_MODELS_VERIFY_SHA="${verify_sha}" \
            CACHED_MODELS_CONFIG_TEMPLATE="${case_root}/template.yaml" \
            CACHED_MODELS_CONFIG_PATH="${config_path}" \
            bash "${validator}" 2>&1)"
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