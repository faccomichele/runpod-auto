# Models: storage, manifest, downloads

Model weights live on the network volume, not in the Docker image. The worker
downloads anything missing from the manifest **on RunPod infrastructure**;
model data never travels through your laptop.

## Volume layout

The volume is mounted at `/runpod-volume` for serverless workers and at
`/workspace` for Pods. ComfyUI finds models via
[`extra_model_paths.yaml`](https://github.com/runpod-workers/worker-comfyui/blob/main/src/extra_model_paths.yaml),
so use these paths in the manifest `dest` field:

| Manifest `dest` prefix | Volume path                     | ComfyUI loader nodes                                   |
| ---------------------- | ------------------------------- | ------------------------------------------------------ |
| `checkpoints/`         | `/runpod-volume/models/checkpoints` | `CheckpointLoaderSimple`                           |
| `unet/`                | `/runpod-volume/models/unet`    | `UNETLoader`, `UnetLoaderGGUF` (diffusion models)      |
| `clip/`                | `/runpod-volume/models/clip`    | `CLIPLoader`, `DualCLIPLoader` (text encoders)         |
| `vae/`                 | `/runpod-volume/models/vae`     | `VAELoader`                                            |
| `loras/`               | `/runpod-volume/models/loras`   | `LoraLoader`, `LoraLoaderModelOnly`                    |
| `controlnet/`          | `/runpod-volume/models/controlnet` | `ControlNetLoader`                                 |
| `upscale_models/`      | `/runpod-volume/models/upscale_models` | `UpscaleModelLoader`                           |

The filenames in the volume must match the names used inside the workflow
(e.g. `CheckpointLoaderSimple.ckpt_name = "my_model.safetensors"`).

## Manifest schema

`models/manifest.json` is baked into the image and is the source of truth.

| Field        | Required | Description                                                                                     |
| ------------ | -------- | ----------------------------------------------------------------------------------------------- |
| `id`         | no       | Human-readable id used in logs (defaults to `dest`)                                             |
| `dest`       | yes      | Destination relative to `<root>/models` (see table above)                                       |
| `url`        | yes      | HTTPS URL: Civitai API, Hugging Face `resolve/main`, S3 pre-signed, any public file URL         |
| `enabled`    | no       | `false` skips the entry (default `true`)                                                        |
| `size_bytes` | no       | Expected exact size; mismatches trigger re-download/audit failure                               |
| `sha256`     | no       | Expected SHA-256 (lowercase hex, optional `sha256:` prefix); verified after download            |
| `auth`       | no       | `{"type":"query","param":"token","env":"CIVITAI_TOKEN"}` or `{"type":"bearer","env":"HF_TOKEN"}` |

- Tokens are read from the named **environment variable** on the endpoint
  (`CIVITAI_TOKEN`, `HF_TOKEN`). Never put token values in the manifest.
- Missing token env vars are logged and the download is attempted unauthenticated
  (public files still work; gated files fail with a clear 401/403 in the logs).
- Downloads go to `<dest>.part` first and are renamed into place only after
  size/SHA checks, so a crashed worker never leaves a half-written model under
  its final name. Existing files with matching size are skipped.

### Loader values: use the dest filename, not the id

Workflow loader nodes (`CheckpointLoaderSimple.ckpt_name`, `LoraLoader.lora_name`,
`VAELoader.vae_name`, ...) must reference the **`dest` basename** - e.g.
`prefectPonyXL_v6.safetensors` - not the manifest `id` (`prefect-pony-xl-v6`).
The `id` is only a label for logs and documentation.

`client/generate.py` checks model-like parameter values against the local
`models/manifest.json` before submitting and fails fast with a suggestion when
you use an `id`, the wrong case, or a disabled entry:

```text
[generate] ERROR: model filename check failed:
  - 'prefect-pony-xl-v6.safetensors' (parameter 'checkpoint') matches the manifest id
    'prefect-pony-xl-v6', not a file on the volume.
    Use the dest filename: prefectPonyXL_v6.safetensors
```

Values that are simply unknown locally only produce a warning (the run
continues), because the local manifest can be stale when you use a volume-local
manifest. Use `--manifest <path>` to check against a different file, or
`--no-model-check` to skip the check entirely.

### Adding a Civitai checkpoint

1. Open the model on Civitai. The URL contains `?modelVersionId=NNNNNN` - copy
   that number (the version you want, not the model id).
2. Add an entry to `models/manifest.json`:

```json
{
  "id": "my-sdxl-checkpoint",
  "dest": "checkpoints/my_sdxl_checkpoint.safetensors",
  "url": "https://civitai.com/api/download/models/NNNNNN",
  "auth": { "type": "query", "param": "token", "env": "CIVITAI_TOKEN" },
  "size_bytes": 0,
  "sha256": ""
}
```

3. Set `CIVITAI_TOKEN` on the endpoint (or the pre-warm Pod).
4. Git tag + GitHub release -> the image rebuild carries the new manifest.
5. Pre-warm or let the first request download it.

Civitai notes:

- Some creators enable "early access" or require login; those downloads need a
  valid token and may still be blocked. Test with `curl -L` from a Pod first.
- Civitai rate-limits downloads per account. If you hit limits, lower
  `BOOTSTRAP_CONNECTIONS` or mirror the file to your own S3 and use a
  pre-signed URL.

### Adding a Hugging Face model

Use the direct file URL (`resolve/main`, not `blob/main`):

```json
{
  "dest": "unet/my_model.safetensors",
  "url": "https://huggingface.co/<org>/<repo>/resolve/main/path/in/repo.safetensors",
  "auth": { "type": "bearer", "env": "HF_TOKEN" }
}
```

`auth` can be omitted for public repos; gated repos (e.g. FLUX.1-dev) need
`HF_TOKEN` and accepted terms on the Hugging Face website.

### Adding a model from your own AWS S3 bucket

**Public object / CloudFront:** put the object URL directly in
`models/manifest.json` with no `auth`. Anyone with the URL can fetch it, so it
is safe to commit (even to a public repo).

**Private bucket:** pre-signed URLs are time-limited bearer secrets (7 days
max). Do not commit them when the repo is public. Put them in a **volume-local
manifest** instead:

1. Download the base manifest to the volume (from a pre-warm Pod; or use the
   [S3-compatible API](https://docs.runpod.io/storage/s3-api)):

```bash
mkdir -p /workspace/config
curl -fsSL https://raw.githubusercontent.com/<you>/runpod-auto/main/models/manifest.json \
  -o /workspace/config/manifest.json
```

2. Generate a pre-signed URL and paste it into the copy (no `auth` block):

```bash
aws s3 presign s3://my-bucket/models/my_model.safetensors --expires-in 604800
# then edit /workspace/config/manifest.json
```

3. Point the endpoint at the volume-local manifest (endpoint env var):
   `MANIFEST_PATH=/runpod-volume/config/manifest.json`.

4. Refresh expired URLs and re-run the bootstrap (or delete the model and
   pre-warm again) - an expired link returns 403 in the bootstrap logs.

## Pre-warming (recommended before large models)

The bootstrap runs at every worker start, but it is cheap when files are
present (size check only). Two ways to populate the volume:

1. **Let the first serverless request do it.** Fine for a single SDXL
   checkpoint (a few GB). The first job just takes longer.
2. **Pre-warm with a Pod (recommended for multiple/large models).**
   1. Deploy a cheap Pod in Secure Cloud with the network volume attached
      (mounted at `/workspace`). Image: the same base tag pinned in the
      `Dockerfile` (`runpod/worker-comfyui:<WORKER_COMFYUI_VERSION>-base`).
   2. Open the web terminal and fetch the bootstrap script + manifest from the
      repo, then run the bootstrap. Public repo shown; for a private repo use
      `git clone` with a read-access PAT instead of `curl`.

```bash
export MODELS_ROOT=/workspace
export CIVITAI_TOKEN=...          # only if the manifest uses Civitai
export HF_TOKEN=...               # optional
curl -fsSL https://raw.githubusercontent.com/<you>/runpod-auto/main/docker/bootstrap-models.sh \
  -o /workspace/bootstrap-models.sh
curl -fsSL https://raw.githubusercontent.com/<you>/runpod-auto/main/models/manifest.json \
  -o /workspace/manifest.json
MANIFEST_PATH=/workspace/manifest.json bash /workspace/bootstrap-models.sh
```

      A Pod terminal cannot read your laptop's `.env`; paste the token values
      there (or set them on the endpoint, where the serverless bootstrap reads
      them automatically).

   3. Audit the result, then terminate the Pod:

```bash
MODELS_ROOT=/workspace MANIFEST_PATH=/workspace/manifest.json \
MODELS_VERIFY_ONLY=true MODELS_VERIFY_SHA=true MODELS_VERIFY_REQUIRE_ALL=true \
  bash /workspace/bootstrap-models.sh
```

Avoid running several serverless workers at the same time while a large
download is in progress: RunPod warns that concurrent writes to a network
volume can corrupt data. The bootstrap uses an advisory lock and atomic
renames, but pre-warming is the safe path.

**Tip:** to swap models without rebuilding the image, copy the manifest to the
volume and point the endpoint at it with `MANIFEST_PATH=/runpod-volume/config/manifest.json`.
Manifest edits then take effect on the next worker start, no release needed.

## Verifying the volume

```bash
# inside any Pod with the volume attached
MODELS_ROOT=/workspace \
MANIFEST_PATH=/workspace/runpod-auto/models/manifest.json \
MODELS_VERIFY_ONLY=true MODELS_VERIFY_SHA=true \
  bash /workspace/runpod-auto/docker/bootstrap-models.sh
```

Env vars: `MODELS_VERIFY_ONLY=true` (no downloads), `MODELS_VERIFY_SHA=true`
(hash existing files), `MODELS_VERIFY_REQUIRE_ALL=true` (exit 1 if anything is
missing). On the endpoint, enable `NETWORK_VOLUME_DEBUG=true` instead to have
the worker print what it sees on the volume.

## Custom nodes

The base image ships core ComfyUI only. Add custom nodes in the `Dockerfile`:

```dockerfile
RUN comfy-node-install comfyui-gguf
```

(Find names on the [Comfy Registry](https://registry.comfy.org).) Custom nodes
require a new release to deploy, and your local workflow must be built with the
same node versions. Prefer core nodes when possible - they never drift.

## Troubleshooting

| Symptom                                        | Cause / fix                                                                                              |
| ---------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `401`/`403` in bootstrap logs                   | Missing/invalid `CIVITAI_TOKEN` or `HF_TOKEN`; check the log line naming the env var.                     |
| `403` on an S3 URL                              | Pre-signed URL expired, or the worker is still using the baked manifest - refresh the URL and point `MANIFEST_PATH` at the volume-local copy. |
| Worker pre-flight: "not found in checkpoints"  | File not on the volume (manifest not deployed, download failed) - run the verify audit.                  |
| Size mismatch on every boot                     | Wrong `size_bytes` in the manifest, or an interrupted download; delete the file and let it re-download.   |
| Download restarts every worker                  | File exists but `size_bytes` is wrong, so it is treated as incomplete.                                   |
| Volume full                                     | Check `df -h` in the bootstrap summary; grow the volume (can only increase) and prune unused models.      |
| Jobs funnel to one worker with a volume          | Update the RunPod SDK: the image pins `runpod>=1.10.1`; rebuild/release if you changed it.                |
