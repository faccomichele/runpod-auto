# Models: RunPod Cached Models

Model weights are supplied by a private Hugging Face **model repository** and
selected in the RunPod endpoint's **Model** field. RunPod exposes the selected
repository through its Hugging Face cache, and the worker reads the files
directly from that cache. The image does not download, copy, or persist model
weights.

Use a model repository, not a Hugging Face Space application. The endpoint
needs a repository id such as `my-org/comfyui-models` and a token with read
access when the repository is private.

## Cached repository layout

Keep the model files and the manifest at the private repository root so the
repository is self-describing:

```text
manifest.json
checkpoints/
clip/
clip_vision/
configs/
controlnet/
diffusion_models/
embeddings/
loras/
model_patches/
sams/
text_encoders/
ultralytics/
unet/
upscale_models/
vae/
```

The paths in `dest` are relative to the repository root:

| Manifest `dest` prefix | ComfyUI loader nodes |
| ---------------------- | -------------------- |
| `checkpoints/`         | `CheckpointLoaderSimple` |
| `unet/`                | `UNETLoader`, `UnetLoaderGGUF` |
| `clip/`                | `CLIPLoader`, `DualCLIPLoader` |
| `text_encoders/`       | text encoder loader nodes |
| `vae/`                 | `VAELoader` |
| `loras/`               | `LoraLoader`, `LoraLoaderModelOnly` |
| `controlnet/`           | `ControlNetLoader` |
| `sams/`                 | SAM loader nodes |
| `ultralytics/`          | Ultralytics and detector nodes |
| `upscale_models/`       | `UpscaleModelLoader` |

At startup the worker resolves the selected repository's `refs/main` snapshot
under `/runpod-volume/huggingface-cache/hub/`, validates the files, and renders
ComfyUI's model path configuration against that snapshot. It never copies the
files into another directory.

## Manifest schema

The private model repository's root `manifest.json` is the runtime inventory.
The worker repository does not duplicate this file. From the runpod-auto root,
the client discovers `./manifest.json` first and then
`../comfyui-personal-collection/manifest.json`; use `--manifest` or
`MODEL_MANIFEST_PATH` to select another copy. The current structure is preserved:

| Field        | Required | Description |
| ------------ | -------- | ----------- |
| `id`          | no       | Human-readable log label; defaults to `dest`. |
| `dest`        | yes      | Safe relative path below the cached repository root. |
| `url`         | no       | Source or provenance URL. It is not fetched by the cached worker. |
| `enabled`     | no       | `false` excludes the entry; default is `true`. |
| `size_bytes`  | no       | Expected exact size; a mismatch fails startup. |
| `sha256`      | no       | Expected SHA-256, optionally prefixed with `sha256:`. Checked when enabled below. |
| `auth`        | no       | Preserved source metadata; it is not used at runtime. |

The validator rejects unsafe paths, missing files, and declared-size
mismatches. Set `CACHED_MODELS_VERIFY_SHA=true` on the endpoint to hash cached
files against their manifest values. Hashing large files adds startup time, so
use it when changing or auditing the repository contents.

URLs and `auth` blocks remain useful for recording where an asset came from,
but the worker never uses them as a fallback. Tokens must not be stored in the
manifest.

### Loader values: use the dest filename, not the id

Workflow loader nodes (`CheckpointLoaderSimple.ckpt_name`,
`LoraLoader.lora_name`, `VAELoader.vae_name`, and similar) reference the
`dest` basename, for example `prefectPonyXL_v6.safetensors`. They must not use
the manifest id `prefect-pony-xl-v6`.

`client/generate.py` checks model-like parameter values against the local
manifest before submission and gives a specific suggestion for an id, case
mismatch, or disabled entry:

```text
[generate] ERROR: model filename check failed:
  - 'prefect-pony-xl-v6.safetensors' (parameter 'checkpoint') matches the manifest id
    'prefect-pony-xl-v6', not a file in the cached repository.
    Use the dest filename: prefectPonyXL_v6.safetensors
```

Values that are simply unknown locally produce a warning because the local
manifest may not yet match the endpoint's repository. Use `--manifest <path>`
to check another manifest, or `--no-model-check` to skip the client check.

## Add or update models

1. Add the asset at `<dest>` in the private Hugging Face repository.
2. Add or update the matching entry in the private repository's root
   `manifest.json`, including `size_bytes` and preferably `sha256`.
3. Commit/push the private repository changes. Prefer a new repository
   id/version when the existing Cached Models entry remains pinned to an older
   snapshot.
4. Set both the endpoint **Model** value and `HF_MODEL_ID` to the new id, or
   ask RunPod support to invalidate the existing cache entry, then restart
   workers so the validator reads the new snapshot.

If the cached snapshot still contains an older file, the validator reports the
size or SHA mismatch and refuses to start. It does not download a replacement.

## Startup behavior

The entrypoint performs these checks before `/start.sh`:

1. `HF_MODEL_ID` is set to an `org/repository` id.
2. RunPod has mounted the selected repository cache and its `refs/main` points
   to a valid snapshot.
3. The snapshot contains root `manifest.json`.
4. Every enabled manifest entry exists under `snapshot/<dest>`.
5. Every declared `size_bytes` value matches.
6. SHA-256 values match when `CACHED_MODELS_VERIFY_SHA=true`.

If `CACHED_MODELS_FETCH_FRESH_MANIFEST=true` is explicitly enabled, the
validator also fetches the private repository's root `manifest.json` using a
separately injected endpoint `HF_TOKEN`. This is a metadata-only diagnostic:
the remote manifest is never used as a model source, and no model files are
downloaded or copied. A missing token, remote fetch failure, or manifest
mismatch stops startup.

Any failure emits a structured `FAIL` record with a stable code, exit status,
repository id, and resolved cache paths, then exits nonzero. Missing repository,
snapshot, or manifest failures also include a bounded listing of the relevant
directory. ComfyUI does not start, and the endpoint cannot accept jobs with a
partially available model set.

### Startup failure codes

| Exit code | Failure code | Meaning |
| --------- | ------------ | ------- |
| `10` | `CACHED_MODELS_CONFIG_*` or `CACHED_MODELS_RUNTIME_MISSING` | Worker configuration or required runtime tool is missing or invalid. |
| `20` | `CACHED_MODELS_CACHE_ROOT_MISSING` or `CACHED_MODELS_REPOSITORY_MISSING` | The Cached Models mount or selected repository was not found. |
| `30` | `CACHED_MODELS_SNAPSHOT_*` | `refs/main` is invalid or its snapshot directory is missing. |
| `40` | `CACHED_MODELS_MANIFEST_*` | Root `manifest.json` is missing or invalid. |
| `50` | `CACHED_MODELS_MODEL_MISMATCH` | An enabled model is missing or fails size/SHA validation. |
| `60` | `CACHED_MODELS_OUTPUT_FAILED` | The ComfyUI path configuration could not be rendered or installed. |
| `70` | `ENTRYPOINT_VALIDATOR_MISSING` | The validator is not executable in the image. |

The optional diagnostic uses exit `10` for missing or invalid runtime-token
configuration and exit `40` for remote manifest fetch, parse, or mismatch
failures (`CACHED_MODELS_REMOTE_MANIFEST_*` and
`CACHED_MODELS_MANIFEST_STALE`).

The entrypoint also emits `CACHED_MODELS_VALIDATION_FAILED` while preserving
the validator's exit code. Use the **Endpoint Logs** view for retained stdout
and stderr. The terminated worker's local **Worker Logs** are temporary and can
disappear with the worker; indefinite retention requires a writable network
volume or an external logging service. Docker cannot add the detailed failure
text to Runpod's separate unhealthy-worker summary.

## Custom nodes

The custom image preinstalls these nodes so workers do not download them at
startup:

- `rgthree-comfy`
- `comfyui_controlnet_aux`
- `comfyui_essentials`
- `comfyui-impact-pack`
- `comfyui-impact-subpack`

Add further nodes in the `Dockerfile` with `comfy-node-install`:

```dockerfile
RUN comfy-node-install comfyui-gguf
```

Find names on the [Comfy Registry](https://registry.comfy.org). The Dockerfile
runs `python main.py --quick-test-for-ci --cpu` after node installation, so
dependency or import failures should stop the image build instead of appearing
only as a runtime worker exit. Custom node changes require a new image release,
and local workflows must use the same node versions.

## Local checks

Run these checks before publishing a worker image:

```bash
bash -n docker/entrypoint.sh docker/validate-cached-models.sh
bash tests/test-cached-models.sh
python -m json.tool ../comfyui-personal-collection/manifest.json > /dev/null
python -m py_compile client/generate.py
```

For an endpoint check, set `HF_MODEL_ID` to the exact value in the RunPod
Model field, send a small representative workflow, and inspect **Endpoint
Logs** for the resolved snapshot and `present` summary. On failure, search for
the `FAIL code=` record and use its `cache_root`, `snapshot_root`, and
`manifest_path` fields. No download command should appear.

## Troubleshooting

| Symptom | Cause / fix |
| ------- | ----------- |
| `HF_MODEL_ID is not set` | Set it to the exact `org/repository` value configured in the endpoint Model field. |
| Cached repository was not found | The endpoint Model field is empty, points to another repository, or the cache has not been prepared yet. Check the repository id and access token. |
| `CACHED_MODELS_MANIFEST_MISSING` | Inspect the preceding `snapshot_root_item=` records. Upload root `manifest.json` to the selected repository and refresh the Cached Models snapshot. |
| `MISSING <dest>` | Upload the file to `<dest>` in the private repository and refresh the endpoint cache. |
| `SIZE <dest>` or `SHA256 <dest>` | Update the manifest to the actual file, or replace the cached file with the intended revision. The worker will not repair it. |
| Only `exit 1` is visible | Open the endpoint's retained **Endpoint Logs** rather than the terminated worker view; the detailed `FAIL code=` record is emitted before exit. |
| `CACHED_MODELS_MANIFEST_STALE` | The optional fresh-manifest check found that RunPod's mounted snapshot is older than Hugging Face `main`. Use a new repository id/version or ask RunPod to invalidate the Cached Models entry; re-entering the same id is not a reliable refresh. |
| `CACHED_MODELS_REMOTE_MANIFEST_TOKEN_MISSING` | Set `CACHED_MODELS_FETCH_FRESH_MANIFEST=true` only when a separate endpoint secret `HF_TOKEN` is configured. The Cached Models credential is not automatically exposed to the worker. |
| `CACHED_MODELS_REMOTE_MANIFEST_FETCH_FAILED` | The metadata-only remote request failed. Check outbound access and the endpoint token, then refresh the Cached Models snapshot; the worker does not download model files as a fallback. |
| Worker refuses to start after a manifest change | Ensure the private HF repository snapshot contains the updated manifest and files. Prefer a new repository id/version or obtain RunPod cache invalidation support, then redeploy the endpoint. |
| ComfyUI says a model is missing | Check that the workflow uses the `dest` basename and that its category matches the repository path, such as `upscale_models/`. |
