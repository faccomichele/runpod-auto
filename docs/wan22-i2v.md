# Phase 2: Wan 2.2 I2V (image-to-video)

Design notes and exact steps for extending the T2I worker to Wan 2.2 I2V using
**core ComfyUI nodes only** (no VHS/WanVideoWrapper). The worker returns
generated videos because ComfyUI's core `SaveVideo`/`SaveWEBM` nodes publish
their files under the history key `images`, which the worker already collects.
Do **not** use `VHS_VideoCombine` - its outputs land under `gifs` and are
ignored by the worker.

## Models to add (all from `Comfy-Org/Wan_2.2_ComfyUI_Repackaged`)

Copy these into `models/manifest.json` (sizes and SHA-256 from Hugging Face):

```json
[
  {
    "id": "wan22-i2v-high-fp8",
    "dest": "unet/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors",
    "url": "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors",
    "size_bytes": 14294742832,
    "sha256": "6122e79d55e0f235698d11d657f3b196c5273c830da00b2b013c5a048d5e6a42"
  },
  {
    "id": "wan22-i2v-low-fp8",
    "dest": "unet/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors",
    "url": "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors",
    "size_bytes": 14294742832,
    "sha256": "5471a457b6ac404202a5fbe6c11595a3d5641fc766b00f38763f72303fffc21e"
  },
  {
    "id": "wan22-umt5",
    "dest": "clip/umt5_xxl_fp8_e4m3fn_scaled.safetensors",
    "url": "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors",
    "size_bytes": 6735906897,
    "sha256": "c3355d30191f1f066b26d93fba017ae9809dce6c627dda5f6a66eaa651204f68"
  },
  {
    "id": "wan22-vae",
    "dest": "vae/wan_2.1_vae.safetensors",
    "url": "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors",
    "size_bytes": 253815318,
    "sha256": "2fc39d31359a4b0a64f55876d8ff7fa8d780956ae2cb13463b0223e15148976b"
  },
  {
    "id": "wan22-lightx2v-high",
    "dest": "loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors",
    "url": "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors",
    "size_bytes": 1226977424,
    "sha256": "d176c808d6fc461999b68e321efcb7501b20b8c3797523ed0df14f7d1deff11e"
  },
  {
    "id": "wan22-lightx2v-low",
    "dest": "loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors",
    "url": "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors",
    "size_bytes": 1226977424,
    "sha256": "024f21de095bc8fad9809ded3e9e49a2e170dcf27075da8145ba7d60d8aab7f9"
  }
]
```

Total: ~38 GB. The lightx2v LoRAs enable 4-step generation (optional but
strongly recommended; without them the default workflow is 20+ steps and much
slower). See [models.md](models.md) for the pre-warm procedure - do pre-warm
before the first video job.

## GPU sizing

| Setup                             | VRAM   | Notes                                                          |
| --------------------------------- | ------ | -------------------------------------------------------------- |
| fp8 high+low + lightx2v LoRAs     | 48 GB  | L40S / RTX 6000 Ada / A6000. Comfortable, recommended.         |
| fp8 + offload (`--lowvram`-style) | 24 GB  | 4090 works but slower; expect block-swap overhead.             |
| GGUF Q4/Q5 quants                 | 24 GB  | Needs `RUN comfy-node-install comfyui-gguf` and Q4_K_M files.  |

Change the endpoint GPU class under **Manage -> Edit Endpoint**; the network
volume keeps the models. Endpoint execution timeout: raise to **1800 s** for
video jobs.

## Workflow

1. Build the I2V workflow in a **local ComfyUI matching the base image pinned
   in the Dockerfile** (`WORKER_COMFYUI_VERSION`) using core nodes:
   - `UNETLoader` (high noise) - `UNETLoader` (low noise)
   - `CLIPLoader` (`type: wan`) with `umt5_xxl_fp8_e4m3fn_scaled`
   - `VAELoader` with `wan_2.1_vae`
   - `LoadImage` (the first frame uploaded by the client)
   - `WanImageToVideo` -> `KSamplerAdvanced` (high) -> `KSamplerAdvanced` (low)
   - Optional `LoraLoaderModelOnly` x2 (lightx2v high/low)
   - `CreateVideo` -> **`SaveVideo`** (or `SaveWEBM`)
2. Export with **Workflow -> Export (API)** into `workflows/wan22_i2v.api.json`
   (gitignored - it is yours).
3. Copy `workflows/examples/t2i_sdxl.params.json` next to it as
   `workflows/wan22_i2v.params.json` and map your node ids, including:

```json
"image":      { "node": "<LoadImage node id>", "input": "image" },
"prompt":     { "node": "<CLIPTextEncode node id>", "input": "text" },
"seed":       { "node": "<KSamplerAdvanced high id>", "input": "noise_seed" },
"length":     { "node": "<WanImageToVideo node id>", "input": "length" },
"steps_high": { "node": "<KSamplerAdvanced high id>", "input": "steps" },
"steps_low":  { "node": "<KSamplerAdvanced low id>", "input": "steps" }
```

`client/generate.py` uploads `--image` as base64 and patches the mapped
`LoadImage` node automatically (see `build_images` in the client).

## Sending a video job

```bash
# default transport: /run + status polling (30-minute result retention)
python client/generate.py \
  --workflow workflows/wan22_i2v.api.json \
  --image first_frame.png \
  --set prompt="slow dolly-in, gentle wind in the trees" \
  --set length=81 --set steps_high=4 --set steps_low=4 \
  --timeout 1800
```

Video jobs run for minutes, so avoid `--runsync` (its HTTP connection is not
held that long). Keep the endpoint's Execution timeout at 1800 s.

## Output delivery

- Video files are returned under `output.images` exactly like images
  (`filename` ends in `.mp4`/`.webm`). Base64 for a 5 s clip can be ~5-15 MB;
  RunPod retention is 30 minutes for async jobs, so the client must save
  immediately (it does).
- For larger/longer videos, configure S3 output on the endpoint:

```
BUCKET_ENDPOINT_URL=https://my-bucket.s3.us-east-1.amazonaws.com
BUCKET_ACCESS_KEY_ID=...
BUCKET_SECRET_ACCESS_KEY=...
```

  The worker then returns `type: "s3_url"` with a pre-signed URL, and a single
  job may hold multiple 720p clips without hitting response-size limits. The
  IAM user needs `s3:PutObject` on the bucket prefix.
- Keep `SaveVideo` settings modest (`format: mp4`, `h264`) for compatibility.

## Checklist

- [ ] Manifest entries added, release deployed, volume pre-warmed with SHA audit.
- [ ] Endpoint GPU raised to 48 GB (or GGUF quants added for 24 GB).
- [ ] Execution timeout 1800 s; max workers kept low during bring-up.
- [ ] Workflow uses core `SaveVideo`/`SaveWEBM` only.
- [ ] S3 output configured if videos exceed ~10 MB.
- [ ] Test job: 2-4 s clip at 480p before going to full resolution/length.
