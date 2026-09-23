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

Keep the same values in your local `.env` (copy `.env.example`) - the client
and scripts read them locally. The local `.env` cannot push variables to
RunPod; the console is the runtime source of truth for the worker.

5. Click **Deploy Endpoint**. Watch **Builds** in the endpoint page. A
   `runpod.serverless.start()` creation warning is expected and harmless - see
   Troubleshooting.

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

Copy `.env.example` to `.env` in the repo root and fill in
`RUNPOD_ENDPOINT_ID` / `RUNPOD_API_KEY` (the client loads `.env`
automatically), then:

```bash
python client/generate.py \
  --set prompt="score_9, score_8_up, score_7_up, 1girl, red hair, autumn leaves, soft lighting" \
  --set checkpoint=prefectPonyXL_v6.safetensors \
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

## 10. Session lifecycle & teardown (ephemeral volume)

Network volumes are billed **hourly for as long as they exist**, even when no
workers are attached. The standard tier is $0.07/GB/month for the first 1 TB
($0.05/GB beyond), roughly:

| Volume | Per hour | 8-hour day | Per month |
| ------ | -------- | ---------- | --------- |
| 50 GB  | ~$0.005  | ~$0.04     | $3.50     |
| 100 GB | ~$0.010  | ~$0.08     | $7.00     |
| 150 GB | ~$0.014  | ~$0.12     | $10.50    |

Deleting the volume stops the charges immediately and **permanently erases all
models on it**. To use a volume only for the day you are working:

### Start of day

1. Create the volume (wrapper around `terraform apply`, or run Terraform
   directly):

   ```powershell
   pwsh -File scripts/session-up.ps1
   ```

   ```bash
   set -a; . ./.env; set +a      # or use scripts/tf.ps1 on Windows
   terraform -chdir=infra apply
   terraform -chdir=infra output -raw volume_id
   ```

2. Attach it to the endpoint: **Endpoint -> Manage -> Edit Endpoint ->
   Advanced -> Network Volumes -> select the volume -> Save Endpoint**.
   Workers restart on the new volume.
3. Pre-warm the models (see
   [models.md -> Pre-warming](models.md#pre-warming-recommended-before-large-models))
   or send your first job and let the worker download them.

### End of day

1. **Detach** the volume from the endpoint (same Advanced -> Network Volumes
   screen, deselect, Save). This prevents the endpoint from pointing at a
   deleted volume.
2. Destroy the volume:

   ```powershell
   pwsh -File scripts/session-down.ps1   # asks you to type 'destroy'
   ```

   ```bash
   set -a; . ./.env; set +a
   terraform -chdir=infra destroy
   ```

3. Confirm it is gone under **Storage** in the console; billing stops at
   deletion.

A new volume gets a **new id**, so next session you attach it to the endpoint
again and re-download models. If you work on this daily, keeping a volume alive
($7/month at 100 GB) is usually cheaper than re-downloading Wan 2.2's ~38 GB
every day.

### Edge cases

On Windows, any Terraform command can go through `scripts/tf.ps1` (it loads
`.env`), e.g. `pwsh -File scripts/tf.ps1 state rm runpod_network_volume.models`.

- **Volume deleted in the console/CLI but still in Terraform state:**

  ```bash
  terraform -chdir=infra state rm runpod_network_volume.models
  ```

- **Volume created outside Terraform and you now want to manage/destroy it**
  (the provider supports import):

  ```bash
  terraform -chdir=infra import runpod_network_volume.models <volume-id>
  ```

- The Terraform state file is local and gitignored. Do not delete it while the
  volume exists, or Terraform loses track of the resource.

### No-Terraform alternative

`runpodctl` manages the lifecycle without a state file (sizes 1-4000 GB):

```bash
runpodctl network-volume create --name comfyui-models --size 100 --data-center-id US-CA-2
runpodctl network-volume list
runpodctl network-volume delete <volume-id>
```

## Troubleshooting

| Symptom                                             | Fix                                                                                                                  |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Build "Testing" step fails                          | Open the build logs. The worker runs a GPU pre-flight at startup; if the failure is "GPU is not available", re-run the build or deploy via GitHub Actions + a registry (section 9). |
| Jobs return "not found in checkpoints"              | The file is missing on the volume. Add it to the manifest, redeploy a release, pre-warm, or run the verify audit.    |
| `NETWORK_VOLUME_DEBUG=true` logs "NOT MOUNTED"      | Attach the volume in endpoint Advanced settings and set workers to 0/1 to force new workers.                          |
| Sizes mismatch / corrupt file                       | Set `MODELS_VERIFY_SHA=true`, run the audit, delete the file on the volume, re-run the bootstrap.                    |
| Download 401/403                                    | Token env var missing/invalid for a gated or Civitai-auth model. Check the bootstrap log lines naming the env var.   |
| Endpoint scaled to 0 after inactivity                | RunPod scales max workers down after 7 idle days; raise max workers in the console.                                   |
| Creation warning `Could not find runpod.serverless.start() in your repo` | Advisory false negative: the handler ships in the base image, not this repo (RunPod reads the Dockerfile by path but checks the handler via GitHub code search, which cannot see inside the image). Confirm **Builds** reaches `Completed` and a test job runs; otherwise ignore. |
