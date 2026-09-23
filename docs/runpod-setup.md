# RunPod setup

End-to-end setup for the custom ComfyUI serverless worker. Everything below
happens in the RunPod console unless noted otherwise.

## Prerequisites

- RunPod account with credits and an [API key](https://www.runpod.io/console/user/settings).
- A GitHub account with this repository pushed (public or private - the
  integration flow is identical).
- A [Civitai API token](https://civitai.com/user/account) (for Civitai downloads).
- Optional: a Hugging Face token for gated models (`HF_TOKEN`).
- Optional: an AWS S3 bucket for outputs (phase 2 / video; not required for T2I).

## 1. Push the repository to GitHub

```bash
git add .
git commit -m "Serverless ComfyUI worker: bootstrap, manifest, client"
git push origin main
```

Keep real workflow exports out of git (they can embed prompts/filenames - they
are gitignored by default; only sanitized examples are committed), and never
commit tokens or pre-signed S3 URLs. Public and private repos both work.

## 2. Connect GitHub to RunPod

1. RunPod console -> **Settings -> Connections -> GitHub -> Connect**.
2. Install the RunPod GitHub App and choose **Only select repositories**,
   selecting this repo (public and private repos are both supported).
3. Validate: **Serverless -> New Endpoint -> Import Git Repository** should now
   list the repo. If it does not, use the fallback in section 9.

## 3. Create the network volume

Models live on a persistent network volume so workers never re-download weights.

- Console -> **Storage -> New Network Volume**.
- Size: **100 GB** for SDXL + FLUX; add ~40 GB for Wan 2.2 I2V later.
- Data center: choose one that
  - has your GPU types in stock (check the GPU filter),
  - supports the [network volume S3 API](https://docs.runpod.io/storage/s3-api#datacenter-availability)
    (optional, but makes pre-warming from a laptop easier),
  - is close to you.
- Note the **volume id**.

Alternatively use the optional Terraform module in [`infra/`](../infra/README.md).

## 4. Create the endpoint from GitHub

1. **Serverless -> New Endpoint -> Import Git Repository**.
2. Repo: this repository, branch `main`, Dockerfile path `/Dockerfile`.
3. Endpoint settings:

| Setting                    | Value                                                                 |
| -------------------------- | --------------------------------------------------------------------- |
| Endpoint type              | Queue                                                                 |
| GPU type(s)                | 4090 PRO (primary), A6000 / A40 48GB (fallback)                       |
| Active workers             | 0                                                                     |
| Max workers                | 1 (raise after the first successful run)                              |
| GPUs per worker            | 1                                                                     |
| Idle timeout               | 5 s (use 10-30 s while iterating; you pay while idle)                 |
| Execution timeout          | 600 s (raise to 1800 s for Wan 2.2 I2V)                               |
| FlashBoot                  | Enabled                                                               |
| Container disk             | 30 GB (the base image is ~15 GB compressed)                           |
| CUDA versions              | 12.8 and all newer (torch cu128 needs driver >= 570)                  |
| Advanced -> Network Volume | select the volume from step 3                                         |

4. Environment variables (endpoint -> Settings -> Environment Variables):

| Variable                    | Example / notes                                                    |
| --------------------------- | ------------------------------------------------------------------ |
| `CIVITAI_TOKEN`             | Civitai API token (model downloads)                                |
| `HF_TOKEN`                  | optional; gated Hugging Face repos                                 |
| `MODELS_BOOTSTRAP`          | `true`                                                             |
| `COMFY_LOG_LEVEL`           | `INFO` (use `DEBUG` while troubleshooting)                         |
| `NETWORK_VOLUME_DEBUG`      | `false` (set `true` to have the worker print a volume file listing) |

> RunPod Secrets (`{{ RUNPOD_SECRET_... }}`) are documented for Pod templates.
> For serverless endpoints, set these env vars directly and rotate the token in
> RunPod/Civitai if it ever leaks. Never commit tokens to the repo.

5. Click **Deploy Endpoint**. Watch **Builds** in the endpoint page.

## 5. Deploy updates

GitHub integration deploys on **new GitHub releases**, not on plain pushes:

```bash
git tag v0.1.0
git push origin v0.1.0
# then create a Release for that tag on GitHub
```

Use **Builds -> Rollback** to return to a previous image.

## 6. Pre-warm the volume (recommended)

The worker image downloads any missing manifest models at startup, so the very
first request already works - it just waits for the download. For small SDXL
checkpoints that is a couple of minutes; for large models, pre-warm once:

See [models.md -> Pre-warming](models.md#pre-warming-recommended-before-large-models).

## 7. First request

```bash
export RUNPOD_ENDPOINT_ID="<endpoint id>"
export RUNPOD_API_KEY="<runpod api key>"

python client/generate.py \
  --set prompt="a red fox in a snowy forest, cinematic" \
  --set checkpoint=<filename from your manifest dest> \
  --set steps=25
```

Outputs land in `out/`. Images are returned as base64 (S3 upload is not
required); async results are retained by RunPod for 30 minutes, so download
them promptly.

To sanity check the endpoint without a checkpoint installed, you can send the
example workflow as-is with a raw `curl` against `/runsync` (it will return a
pre-flight error listing available checkpoints if the file is missing - that
error confirms the worker is alive and the volume is detected).

## 8. Environment variable reference (worker)

| Variable                    | Default              | Purpose                                                |
| --------------------------- | -------------------- | ------------------------------------------------------ |
| `MODELS_ROOT`               | `/runpod-volume`     | model storage root; Pods use `/workspace`               |
| `MANIFEST_PATH`             | `/models/manifest.json` | manifest baked into the image                        |
| `MODELS_BOOTSTRAP`          | `true`               | disable with `false`                                   |
| `BOOTSTRAP_STRICT`          | `false`              | fail worker startup on download errors                 |
| `DOWNLOAD_ONLY`             | `false`              | pre-warm mode: bootstrap then exit                     |
| `MODELS_VERIFY_ONLY`        | `false`              | audit volume contents without downloading              |
| `MODELS_VERIFY_SHA`         | `false`              | also verify sha256 of existing files                   |
| `MODELS_VERIFY_REQUIRE_ALL` | `false`              | audit exits 1 when files are missing                   |
| `BOOTSTRAP_RETRIES`         | `3`                  | download retries per file                              |
| `BOOTSTRAP_CONNECTIONS`     | `8`                  | parallel connections per file                          |
| `BUCKET_ENDPOINT_URL`       | unset                | S3 output upload (phase 2); bucket name in the URL     |
| `BUCKET_ACCESS_KEY_ID`      | unset                | S3 output credentials                                  |
| `BUCKET_SECRET_ACCESS_KEY`  | unset                | S3 output credentials                                  |

## 9. Fallback: deploy from a registry

If the GitHub integration is unavailable or the repo does not appear in the
Import list, build the image in GitHub Actions and deploy from a registry
instead:

1. Build and push to private Docker Hub or GHCR on release.
2. **Serverless -> New Endpoint -> Import from Docker Registry**.
3. Enter the image reference and configure the registry credentials.
4. All other settings (volume, env vars, GPU) are identical to section 4.

## Troubleshooting

| Symptom                                             | Fix                                                                                                                  |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Build "Testing" step fails                          | Open the build logs. The worker runs a GPU pre-flight at startup; if the failure is "GPU is not available", re-run the build or deploy via GitHub Actions + a registry (section 9). |
| Jobs return "not found in checkpoints"              | The file is missing on the volume. Add it to the manifest, redeploy a release, pre-warm, or run the verify audit.    |
| `NETWORK_VOLUME_DEBUG=true` logs "NOT MOUNTED"      | Attach the volume in endpoint Advanced settings and set workers to 0/1 to force new workers.                          |
| Sizes mismatch / corrupt file                       | Set `MODELS_VERIFY_SHA=true`, run the audit, delete the file on the volume, re-run the bootstrap.                    |
| Download 401/403                                    | Token env var missing/invalid for a gated or Civitai-auth model. Check the bootstrap log lines naming the env var.   |
| Endpoint scaled to 0 after inactivity                | RunPod scales max workers down after 7 idle days; raise max workers in the console.                                   |
