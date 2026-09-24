# runpod-auto

Serverless ComfyUI on RunPod: author workflows locally, export them as API
JSON, and submit jobs over HTTP. Model weights are supplied by a private
Hugging Face model repository through RunPod Cached Models, so the worker can
start quickly without downloading or storing model files itself.

- **v1 (this repo):** text-to-image with SDXL / SD 1.5 checkpoints.
- **Phase 2:** Wan 2.2 image-to-video - see [docs/wan22-i2v.md](docs/wan22-i2v.md).

## How it works

```text
local laptop                    RunPod build                    RunPod endpoint
------------                    -----------                    --------------
ComfyUI                         GitHub release                 private HF model
  Workflow > Export (API)  -->  worker-comfyui image       -->  repository cache
workflows/*.api.json            + cache validator                  models/<dest>
                                                      |
client/generate.py  -------- HTTPS ------------------------------>  ComfyUI worker
  prompt/seed/image                                             validates, loads, runs
                                            outputs: base64/S3
```

1. RunPod's GitHub integration builds the worker image from this repository.
2. The endpoint's **Model** setting selects the private Hugging Face repository
  and `HF_MODEL_ID` identifies that same repository to the custom worker.
3. `/entrypoint.sh` resolves the cached snapshot, validates every enabled
  manifest entry, configures ComfyUI, and refuses to start if a model is
  missing or does not match its declared size.
4. `client/generate.py` merges prompts and parameters into the exported workflow,
  submits it, and saves images or videos locally.

## Repository layout

```
Dockerfile                  worker image: worker-comfyui base + cache validator
docker/
  entrypoint.sh             cache validation gate -> stock /start.sh
  validate-cached-models.sh read-only cache and manifest validator
  extra_model_paths.yaml    ComfyUI model path template
models/manifest.json        model inventory and destinations
workflows/examples/         sanitized example workflow + parameter map
client/generate.py          CLI: submit, poll, save outputs (stdlib only)
.env.example                template for tokens/ids (copy to .env; .env is ignored)
docs/
  runpod-setup.md           console walkthrough (GitHub, cache, endpoint)
  models.md                 manifest format, cache layout, validation
  wan22-i2v.md              phase-2 model list and workflow notes
```

## Quickstart

```bash
# 1. Upload the model files and matching models/manifest.json to a private
#    Hugging Face model repository. See docs/models.md.

# 2. Push this worker repo to GitHub and follow docs/runpod-setup.md to connect
#    RunPod, select the cached model, and deploy the endpoint.

# 3. Create your local client env file and fill in the values:
cp .env.example .env          # Windows: Copy-Item .env.example .env

# 4. Run a job from your laptop (the client auto-loads .env):
python client/generate.py \
  --set prompt="a red fox in a snowy forest, cinematic lighting" \
  --set checkpoint=prefectPonyXL_v6.safetensors \
  --set steps=30
```

Outputs are written to `out/`. `python client/generate.py --show-params` lists
the parameters available in the example workflow. Use `--workflow
workflows/my_workflow.api.json` for your own exports (copy the params map next
to it or pass `--params`).

The client waits for jobs using `/run` + `/status` polling (30-minute result
retention), which is the safe default for cache initialization and long jobs.
`--runsync` uses the literal sync endpoint for short, already-running workers.
Transient failures are retried (`--retries`, `--retry-delay`); see `--help` for
`--timeout`, `--sync-timeout` and `--retry-duplicate`.

### Workflow authoring

1. Build/test the workflow in a local ComfyUI that matches the base image
   pinned in the `Dockerfile` (`WORKER_COMFYUI_VERSION`; check the tag's release
   notes for its ComfyUI version). Use only nodes that exist in the worker image.
2. **Workflow -> Export (API)** into `workflows/` (gitignored - exports can
   contain prompts/filenames you may not want in git).
3. Map logical names to nodes in a `<name>.params.json` file; the client applies
   `--set` overrides through that map, so node ids are never hand-edited.
4. Loader values use the manifest **`dest` basename** (e.g.
   `prefectPonyXL_v6.safetensors`), never the manifest `id`. The client checks
   model filenames against `models/manifest.json` before submitting
   (`--no-model-check` to skip).

## Configuration

Worker environment variables (endpoint -> Settings):

| Variable                    | Purpose                                                    |
| --------------------------- | ---------------------------------------------------------- |
| `HF_MODEL_ID`               | Cached private Hugging Face repository, for example `my-org/comfyui-models`. |
| `CACHED_MODELS_VERIFY_SHA`  | `true` hashes cached files against manifest SHA-256 values. |
| `BUCKET_ENDPOINT_URL`  | optional S3 output upload (phase 2 / large videos)         |
| `BUCKET_ACCESS_KEY_ID` / `BUCKET_SECRET_ACCESS_KEY` | S3 output credentials |

The image enables `HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1` after the
cache check. Runtime validation reads `models/manifest.json` from the selected
cached repository; the worker-repository copy is used only for local client
filename checks. There is no runtime model download fallback.

Full reference: [docs/runpod-setup.md](docs/runpod-setup.md#8-environment-variable-reference-worker).

## Visibility & secrets

- The repo can be **public**: nothing committed is sensitive. Real workflow
  exports are still gitignored (they can embed prompts, input image names and
  other PII) - that is a workflow-privacy choice, not a repo-visibility one.
- Prompts and input images travel only over the RunPod API - never to GitHub.
- The Hugging Face read token is configured with the endpoint's cached-model
  setting. Never commit it. S3 output keys live in the local `.env` and endpoint
  settings; `.env.example` is the committed template.
- Manifest URLs and `auth` blocks are source metadata only. The cached worker
  does not use them to fetch model files.
- A gitleaks secret scan runs on pushes/PRs (`.github/workflows/secret-scan.yml`).
- `.dockerignore` keeps `client/`, `workflows/`, and `docs/` out of the image
  build context.

## Development / validation

```bash
bash -n docker/entrypoint.sh docker/validate-cached-models.sh
python -m py_compile client/generate.py
python -m json.tool models/manifest.json > /dev/null
```

For endpoint validation, set `HF_MODEL_ID` to the exact RunPod Model value and
inspect the worker logs for the resolved snapshot and a zero-missing summary.

## Credits

Built on [runpod-workers/worker-comfyui](https://github.com/runpod-workers/worker-comfyui)
and [ComfyUI](https://github.com/comfyanonymous/ComfyUI).
