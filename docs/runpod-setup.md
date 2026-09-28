# RunPod setup

End-to-end setup for the custom ComfyUI Serverless worker using RunPod Cached
Models. The worker image contains ComfyUI and the cache validator; model files
come from a private Hugging Face model repository selected during endpoint
creation.

## Prerequisites

- RunPod account with credits and an [API key](https://www.runpod.io/console/user/settings).
- This worker repository pushed to GitHub (public or private).
- A private Hugging Face **model repository**, not a Space application.
- A Hugging Face fine-grained read token that can access that repository.
- Optional: an AWS S3 bucket for output delivery in phase 2.

## 1. Prepare the private model repository

Create a private model repository such as `my-org/comfyui-models`. Upload the
model files and manifest using the layout described in
[Models: RunPod Cached Models](models.md):

```text
manifest.json
checkpoints/
clip/
controlnet/
loras/
sams/
text_encoders/
ultralytics/
unet/
upscale_models/
vae/
```

Upload each file at the exact path represented by its manifest `dest` value.
Keep the root `manifest.json` in the private model repository; this worker
repository intentionally has no duplicate model manifest. Never place access
tokens in the manifest.

Create a Hugging Face fine-grained access token from **Settings -> Access
Tokens** with read access to this model repository. Copy the token when it is
created; it is entered in RunPod's cached-model configuration during endpoint
creation and is not automatically added to the worker environment. The
optional stale-cache diagnostic described below requires a separate endpoint
secret named `HF_TOKEN`; do not expose the Cached Models credential through
application environment variables unless you intentionally configure that
separate secret.

## 2. Push the worker repository to GitHub

```bash
git add .
git commit -m "Serverless ComfyUI worker: cached models"
git push origin main
```

Keep real workflow exports out of git. They are gitignored by default because
they can contain prompts, filenames, and input-image details.

## 3. Connect GitHub to RunPod

1. RunPod console -> **Settings -> Connections -> GitHub -> Connect**.
2. Install the RunPod GitHub App and select this repository.
3. Confirm that **Serverless -> New Endpoint -> Import Git Repository** lists
  the repository. If it does not, use the registry fallback below.

## 4. Create the endpoint

1. Select **Serverless -> New Endpoint -> Import Git Repository**.
2. Choose this repository, branch `main`, and Dockerfile path `/Dockerfile`.
3. In endpoint configuration, set **Model** to the private repository id, for
  example `my-org/comfyui-models`.
4. Add the Hugging Face access token when RunPod prompts for the private model.
  RunPod uses this setting to populate its Cached Models cache.
5. Add `HF_MODEL_ID` as an endpoint environment variable with the exact same
  value: `my-org/comfyui-models`.

Recommended initial settings:

| Setting | Value |
| ------- | ----- |
| Endpoint type | Queue |
| GPU type(s) | 4090 PRO, then A6000 / A40 48GB fallback |
| Active workers | 0 while validating |
| Max workers | 1 until the first successful request |
| GPUs per worker | 1 |
| Idle timeout | 300 s while iterating; reduce after validation |
| Execution timeout | 1800 s for image-to-video workloads |
| FlashBoot | Enabled |
| Container disk | 30 GB or more for the worker image and runtime |
| CUDA versions | 12.8 and newer compatible versions |

The **Model** setting selects the cache. `HF_MODEL_ID` tells the custom worker
which cached repository to resolve. The values must match exactly.

## 5. Deploy and verify

Click **Deploy Endpoint** and watch **Builds**. On worker startup, logs should
include a resolved snapshot and lines like:

```text
[cached-models] present checkpoints/my_model.safetensors
[cached-models] summary: repository=my-org/comfyui-models snapshot=... present=... missing=0 mismatches=0
[cached-models] ComfyUI model paths configured from ...
```

The worker exits with a warning if the repository is missing, a file is absent,
or a declared size does not match. It emits a `FAIL code=` record with the
failure class, exit code, repository id, and relevant cache paths before it
exits. It does not download a replacement.

For temporary stale-cache diagnosis, set
`CACHED_MODELS_FETCH_FRESH_MANIFEST=true` and inject a separate endpoint
secret named `HF_TOKEN`. The validator fetches only the private repository's
root manifest from Hugging Face, compares its enabled inventory with the
mounted snapshot, and fails closed on a mismatch. It never downloads or copies
model files, and never logs the token. Leave this option disabled during normal
operation.

Use the endpoint's **Logs** tab, which retains worker stdout/stderr, when
diagnosing startup failures. The local **Worker Logs** view is temporary and
may disappear after an unhealthy worker terminates. The validator uses these
exit classes: `10` configuration/runtime, `20` cache/repository, `30` snapshot,
`40` manifest, `50` model contents, `60` rendered configuration, and `70`
missing entrypoint validator. Indefinite retention requires a writable network
volume or an external logging service; the Docker image does not persist logs
after the container exits.

## 6. First request

Copy `.env.example` to `.env` and fill in `RUNPOD_ENDPOINT_ID` and
`RUNPOD_API_KEY` for the client:

```bash
python client/generate.py \
  --set prompt="score_9, score_8_up, score_7_up, 1girl, red hair, autumn leaves, soft lighting" \
  --set checkpoint=prefectPonyXL_v6.safetensors \
  --set steps=25
```

Outputs land in `out/`. The default client transport uses `/run` and status
polling, which is appropriate for cache initialization and long video jobs.
Use `--runsync` only for short, already-running workers.

## 7. Deploy updates

When model files change:

1. Update the private repository and its root `manifest.json`.
2. Prefer a new repository id/version, such as
  `my-org/comfyui-models-v2`, when the existing Cached Models entry remains
  pinned to an older snapshot.
3. Set both the endpoint **Model** value and `HF_MODEL_ID` to the new id, then
  redeploy and restart workers before sending production traffic.
4. If the repository id must remain unchanged, ask RunPod support to
  invalidate or refresh the Cached Models entry. Removing and re-adding the
  same value is not reliable evidence that its snapshot was rebuilt.

The mounted `refs/main` file is the authoritative revision for a worker. A
local `hf download --revision main` command queries Hugging Face directly and
does not update RunPod's existing cache.

GitHub integration deploys on **new GitHub releases**, not plain pushes:

```bash
git tag v0.1.0
git push origin v0.1.0
# Create a GitHub release for the tag.
```

## 8. Environment variable reference

| Variable | Default | Purpose |
| -------- | ------- | ------- |
| `HF_MODEL_ID` | unset | Exact private Hugging Face repository id from the endpoint Model field. Required. |
| `CACHED_MODELS_VERIFY_SHA` | `false` | Hash cached files against manifest SHA-256 values. |
| `CACHED_MODELS_FETCH_FRESH_MANIFEST` | `false` | Explicitly fetch and compare only the root manifest. Requires endpoint-only `HF_TOKEN`; no model files are downloaded. |
| `HF_TOKEN` | unset | Separate endpoint secret required only when the fresh-manifest diagnostic is enabled. Never put it in the local `.env` or image. |
| `COMFY_LOG_LEVEL` | `DEBUG` | ComfyUI logging level. |
| `BUCKET_ENDPOINT_URL` | unset | Optional S3 output endpoint for phase 2. |
| `BUCKET_ACCESS_KEY_ID` | unset | Optional S3 output credential. |
| `BUCKET_SECRET_ACCESS_KEY` | unset | Optional S3 output credential. |

The image sets `HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1` after cache
validation so runtime code cannot silently download a model. The optional
manifest diagnostic uses a controlled standard-library metadata request before
that handoff; it is not a model-download fallback.

## 9. Fallback: deploy from a registry

If the GitHub integration is unavailable:

1. Build and push the image to a private Docker Hub or GHCR repository.
2. Select **Serverless -> New Endpoint -> Import from Docker Registry**.
3. Configure the image, private model in **Model**, `HF_MODEL_ID`, GPU, and
  worker settings as above.

## Troubleshooting

| Symptom | Fix |
| ------- | --- |
| `HF_MODEL_ID is not set` | Add the exact repository id used in the endpoint Model field. |
| Cached repository was not found | Verify the Model field, repository permissions, and Hugging Face token. |
| `CACHED_MODELS_MANIFEST_MISSING` | Use the preceding `snapshot_root_item=` lines to inspect the cached snapshot, then upload root `manifest.json` and refresh the Cached Models snapshot. |
| `MISSING <dest>` | Upload the file to `<dest>` in the private repository and refresh the cache. |
| `SIZE <dest>` or `SHA256 <dest>` | Make the cached file and manifest agree, then restart the endpoint. |
| Only `exit 1` is visible | Open the endpoint **Logs** tab for retained stdout/stderr; the terminated worker view may no longer contain the detailed failure record. |
| Jobs report a missing ComfyUI model | Use the `dest` basename in the workflow and confirm its category, such as `upscale_models/`. |
| Build "Testing" fails | Inspect the build logs for GPU or base-image errors, then retry the build or use the registry fallback. |
| `RemoteDisconnected` on submit | Use the default `/run` plus polling transport for long jobs. Check the Requests tab before retrying an ambiguous submission. |
| Endpoint scaled down after inactivity | Raise the worker limits in the endpoint console before testing again. |
| `Could not find runpod.serverless.start()` warning | This is an advisory GitHub inspection warning; the handler is supplied by the base image. Confirm that the build completes and a request runs. |
