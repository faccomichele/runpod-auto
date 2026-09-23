# runpod-auto

Serverless ComfyUI on RunPod: author workflows locally, export them as API
JSON, and submit jobs over HTTP. The worker downloads all model weights from
Civitai, Hugging Face or your own S3 bucket straight onto a persistent network
volume - model data never flows through your laptop.

- **v1 (this repo):** text-to-image with any SDXL / SD 1.5 Civitai checkpoint.
- **Phase 2:** Wan 2.2 image-to-video - see [docs/wan22-i2v.md](docs/wan22-i2v.md).

## How it works

```
local laptop                    RunPod (GitHub integration)            RunPod runtime
────────────                    ───────────────────────────            ──────────────
ComfyUI                        builds Dockerfile on each             Serverless endpoint
  Workflow > Export (API)  ──▶   GitHub release                    ─┐  (4090 / 48GB GPU)
workflows/*.api.json           image: worker-comfyui + bootstrap   │
                                                                   ├─ /runpod-volume/models
  client/generate.py ──HTTPS──────────────────────────────────────┘    (checkpoints, unet, clip,
  (prompt/seed/image)            model bootstrap pulls from             vae, loras, ...)
                                 Civitai / Hugging Face / S3         └─ outputs: base64 (default)
workflows stay local (gitignored)                                       or S3 URLs (optional)
```

1. The custom image is built from this repo by **RunPod's GitHub integration**
   on every GitHub release.
2. At worker startup `/entrypoint.sh` runs `docker/bootstrap-models.sh`, which
   reads `models/manifest.json` and downloads any missing files onto the
   mounted network volume. Downloads are idempotent and verified by size/SHA.
3. `client/generate.py` merges prompts/params into your exported workflow and
   submits it to the endpoint, then saves images (or videos later) locally.

## Repository layout

```
Dockerfile                  worker image: worker-comfyui base + bootstrap layer
docker/
  entrypoint.sh             bootstrap gate -> stock /start.sh (DOWNLOAD_ONLY pre-warm mode)
  bootstrap-models.sh       idempotent, resumable model downloader
models/manifest.json        model URLs (Civitai / HF / S3) and destinations
workflows/examples/         sanitized example workflow + parameter map
client/generate.py          CLI: submit, poll, save outputs (stdlib only)
infra/                      optional Terraform for the network volume
scripts/                    env/tf/session helpers (all load .env)
.env.example                template for tokens/ids (copy to .env; .env is ignored)
docs/
  runpod-setup.md           console walkthrough (GitHub integration, volume, env)
  models.md                 manifest format, Civitai/HF/S3, pre-warming, audits
  wan22-i2v.md              phase-2 model list and workflow notes
```

## Quickstart

```bash
# 1. Push this repo to a GitHub repository (public or private - both work
#    with RunPod's GitHub integration).

# 2. Follow docs/runpod-setup.md to connect RunPod, create the volume,
#    deploy the endpoint from this repo, and set CIVITAI_TOKEN.

# 3. Create your local env file and fill in the values:
cp .env.example .env          # Windows: Copy-Item .env.example .env

# 4. Run a job from your laptop (the client auto-loads .env):
python client/generate.py \
  --set prompt="a red fox in a snowy forest, cinematic lighting" \
  --set checkpoint=my_sdxl_checkpoint.safetensors \
  --set steps=30
```

Outputs are written to `out/`. `python client/generate.py --show-params` lists
the parameters available in the example workflow. Use `--workflow
workflows/my_workflow.api.json` for your own exports (copy the params map next
to it or pass `--params`).

For an ephemeral, per-session volume (`scripts/session-up.ps1` /
`scripts/session-down.ps1`) see
[docs/runpod-setup.md -> Session lifecycle](docs/runpod-setup.md#10-session-lifecycle--teardown-ephemeral-volume).

### Workflow authoring

1. Build/test the workflow in a local ComfyUI that matches the base image
   pinned in the `Dockerfile` (`WORKER_COMFYUI_VERSION`; check the tag's release
   notes for its ComfyUI version). Use only nodes that exist in the worker image.
2. **Workflow -> Export (API)** into `workflows/` (gitignored - exports can
   contain prompts/filenames you may not want in git).
3. Map logical names to nodes in a `<name>.params.json` file; the client applies
   `--set` overrides through that map, so node ids are never hand-edited.

## Configuration

Worker environment variables (endpoint -> Settings):

| Variable               | Purpose                                                    |
| ---------------------- | ---------------------------------------------------------- |
| `CIVITAI_TOKEN`        | Civitai downloads (manifest `auth`)                        |
| `HF_TOKEN`             | gated Hugging Face repos                                   |
| `MODELS_BOOTSTRAP`     | `false` disables the downloader (default `true`)           |
| `DOWNLOAD_ONLY`        | `true` = pre-warm mode: download then exit                 |
| `MODELS_VERIFY_ONLY`   | audit the volume without downloading                       |
| `MANIFEST_PATH`        | override manifest path (e.g. a copy on the volume)         |
| `BUCKET_ENDPOINT_URL`  | optional S3 output upload (phase 2 / large videos)         |
| `BUCKET_ACCESS_KEY_ID` / `BUCKET_SECRET_ACCESS_KEY` | S3 output credentials |
| `NETWORK_VOLUME_DEBUG` | worker prints a volume file listing for debugging          |

Full reference: [docs/runpod-setup.md](docs/runpod-setup.md#8-environment-variable-reference-worker).

## Visibility & secrets

- The repo can be **public**: nothing committed is sensitive. Real workflow
  exports are still gitignored (they can embed prompts, input image names and
  other PII) - that is a workflow-privacy choice, not a repo-visibility one.
- Prompts and input images travel only over the RunPod API - never to GitHub.
- Tokens (`CIVITAI_TOKEN`, `HF_TOKEN`, S3 output keys) are endpoint environment
  variables set in the RunPod console. Never commit them. Locally they live in
  `.env` (gitignored); `.env.example` is the committed template and the tools
  auto-load it.
- Pre-signed S3 model URLs are time-limited bearer secrets. Keep them in a
  volume-local manifest and point the endpoint at it with `MANIFEST_PATH`
  (see [docs/models.md](docs/models.md#adding-a-model-from-your-own-aws-s3-bucket));
  the committed manifest should hold public URLs only.
- A gitleaks secret scan runs on pushes/PRs (`.github/workflows/secret-scan.yml`).
- `.dockerignore` keeps `client/`, `workflows/`, `docs/`, `infra/` out of the
  image build context.

## Development / validation

```bash
bash -n docker/entrypoint.sh docker/bootstrap-models.sh
python -m py_compile client/generate.py
python -m json.tool models/manifest.json > /dev/null
cd infra && terraform fmt -check && terraform validate   # optional
```

Local bootstrap smoke test (Git Bash / WSL / Linux; downloads one small file):

```bash
MODELS_ROOT="$(mktemp -d)" MANIFEST_PATH=models/manifest.json \
  bash docker/bootstrap-models.sh
MODELS_ROOT="<same dir>" MANIFEST_PATH=models/manifest.json \
  MODELS_VERIFY_ONLY=true bash docker/bootstrap-models.sh
```

## Credits

Built on [runpod-workers/worker-comfyui](https://github.com/runpod-workers/worker-comfyui)
and [ComfyUI](https://github.com/comfyanonymous/ComfyUI).
