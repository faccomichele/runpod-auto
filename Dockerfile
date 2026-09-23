# syntax=docker/dockerfile:1

# Custom RunPod Serverless ComfyUI worker.
#
# Starts from the official worker-comfyui base image (ComfyUI + RunPod handler)
# and adds the "model bootstrap" layer:
#
#   /entrypoint.sh        gate that downloads/verifies models, then execs /start.sh
#   /usr/local/bin/bootstrap-models.sh
#                         idempotent downloader driven by /models/manifest.json
#   /models/manifest.json model URLs (Civitai / Hugging Face / S3 presigned)
#
# Models are stored on the attached network volume (/runpod-volume/models), never
# baked into the image. Before bumping WORKER_COMFYUI_VERSION, make sure the
# corresponding "-base" tag exists on Docker Hub (releases and image tags can
# lag each other):
#   https://hub.docker.com/r/runpod/worker-comfyui/tags
#   https://github.com/runpod-workers/worker-comfyui/releases
ARG WORKER_COMFYUI_VERSION=5.10.0

FROM runpod/worker-comfyui:${WORKER_COMFYUI_VERSION}-base

# aria2 for parallel, resumable downloads (wget fallback is already present);
# curl is used by operational helpers/tests.
RUN apt-get update \
    && apt-get install -y --no-install-recommends aria2 ca-certificates curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Pin the RunPod SDK to a version that fixes network-volume job tracking
# (affected: 1.7.11 - 1.10.0, fixed in 1.10.1+).
RUN VIRTUAL_ENV=/opt/venv uv pip install --no-cache "runpod>=1.10.1"

COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/bootstrap-models.sh /usr/local/bin/bootstrap-models.sh
COPY models/manifest.json /models/manifest.json

RUN chmod +x /entrypoint.sh /usr/local/bin/bootstrap-models.sh

# Override the base image CMD (["/start.sh"]) with the bootstrap gate, which
# execs /start.sh once models are in place.
CMD ["/entrypoint.sh"]
