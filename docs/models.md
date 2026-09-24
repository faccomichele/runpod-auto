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

Mirror the worker's model tree under `models/` in the private repository. Keep
the manifest copy alongside the files so the repository is self-describing:

```text
models/
  manifest.json
  checkpoints/
  clip/
  controlnet/
  diffusion_models/
  embeddings/
  loras/
  model_patches/
  text_encoders/
  unet/
  upscale_models/
  vae/
```

The paths in `dest` are relative to this `models/` directory:

| Manifest `dest` prefix | ComfyUI loader nodes |
| ---------------------- | -------------------- |
| `checkpoints/`         | `CheckpointLoaderSimple` |
| `unet/`                | `UNETLoader`, `UnetLoaderGGUF` |
| `clip/`                | `CLIPLoader`, `DualCLIPLoader` |
| `text_encoders/`       | text encoder loader nodes |
| `vae/`                 | `VAELoader` |
| `loras/`               | `LoraLoader`, `LoraLoaderModelOnly` |
| `controlnet/`           | `ControlNetLoader` |
| `upscale_models/`       | `UpscaleModelLoader` |

At startup the worker resolves the selected repository's `refs/main` snapshot
under `/runpod-volume/huggingface-cache/hub/`, validates the files, and renders
ComfyUI's model path configuration against that snapshot. It never copies the
files into another directory.

## Manifest schema

The private model repository's `models/manifest.json` is the runtime inventory.
The worker repository keeps the same file for local client validation. Keep the
two copies synchronized. The current structure is preserved:

| Field        | Required | Description |
| ------------ | -------- | ----------- |
| `id`          | no       | Human-readable log label; defaults to `dest`. |
| `dest`        | yes      | Safe relative path below the cached repository's `models/` directory. |
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

1. Add the asset under `models/<dest>` in the private Hugging Face repository.
2. Add or update the matching entry in the worker repository's
   `models/manifest.json`, including `size_bytes` and preferably `sha256`.
3. Copy the updated manifest into the private repository at
   `models/manifest.json`.
4. Commit/push the private repository changes and update the endpoint so RunPod
   refreshes the selected cache snapshot.
5. Restart the endpoint or its workers so the validator reads the new snapshot.

If the cached snapshot still contains an older file, the validator reports the
size or SHA mismatch and refuses to start. It does not download a replacement.

## Startup behavior

The entrypoint performs these checks before `/start.sh`:

1. `HF_MODEL_ID` is set to an `org/repository` id.
2. RunPod has mounted the selected repository cache and its `refs/main` points
   to a valid snapshot.
3. The snapshot contains `models/manifest.json`.
4. Every enabled manifest entry exists under `snapshot/models/<dest>`.
5. Every declared `size_bytes` value matches.
6. SHA-256 values match when `CACHED_MODELS_VERIFY_SHA=true`.

Any failure logs a `WARN` line and exits nonzero. ComfyUI does not start, and
the endpoint cannot accept jobs with a partially available model set.

## Custom nodes

The base image ships core ComfyUI only. Add custom nodes in the `Dockerfile`:

```dockerfile
RUN comfy-node-install comfyui-gguf
```

Find names on the [Comfy Registry](https://registry.comfy.org). Custom nodes
require a new image release, and local workflows must use the same node
versions.

## Local checks

Run these checks before publishing a worker image:

```bash
bash -n docker/entrypoint.sh docker/validate-cached-models.sh
python -m json.tool models/manifest.json > /dev/null
python -m py_compile client/generate.py
```

For an endpoint check, set `HF_MODEL_ID` to the exact value in the RunPod
Model field, send a small representative workflow, and inspect the startup
logs for the resolved snapshot and `present` summary. No download command
should appear.

## Troubleshooting

| Symptom | Cause / fix |
| ------- | ----------- |
| `HF_MODEL_ID is not set` | Set it to the exact `org/repository` value configured in the endpoint Model field. |
| Cached repository was not found | The endpoint Model field is empty, points to another repository, or the cache has not been prepared yet. Check the repository id and access token. |
| `MISSING <dest>` | Upload the file to `models/<dest>` in the private repository and refresh the endpoint cache. |
| `SIZE <dest>` or `SHA256 <dest>` | Update the manifest to the actual file, or replace the cached file with the intended revision. The worker will not repair it. |
| Worker refuses to start after a manifest change | Ensure the private repository snapshot contains the updated manifest and files, then refresh the endpoint cache. |
| ComfyUI says a model is missing | Check that the workflow uses the `dest` basename and that its category matches the repository path, such as `upscale_models/`. |
