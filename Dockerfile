# syntax=docker/dockerfile:1

# Custom RunPod Serverless ComfyUI worker.
#
# Starts from the official worker-comfyui base image (ComfyUI + RunPod handler)
# and adds the Cached Models integration:
#
#   /entrypoint.sh        validates the cache, then execs /start.sh
#   /usr/local/bin/validate-cached-models.sh
#                         read-only manifest/cache validator
#   cached repository/models/manifest.json runtime model inventory
#
# Model weights are supplied by RunPod Cached Models and are never downloaded
# or baked into this image. Before bumping WORKER_COMFYUI_VERSION, make sure the
# corresponding "-base" tag exists on Docker Hub (releases and image tags can
# lag each other):
#   https://hub.docker.com/r/runpod/worker-comfyui/tags
#   https://github.com/runpod-workers/worker-comfyui/releases
ARG WORKER_COMFYUI_VERSION=5.10.0

FROM runpod/worker-comfyui:${WORKER_COMFYUI_VERSION}-base

# Install custom nodes into the image so workers do not fetch them at startup.
RUN comfy-node-install \
	rgthree-comfy \
	comfyui_controlnet_aux \
	comfyui_essentials \
	comfyui-impact-pack \
	comfyui-impact-subpack

# Import every installed node during the build, where dependency failures are
# visible instead of becoming an opaque worker exit at runtime.
RUN cd /comfyui && timeout 300 python main.py --quick-test-for-ci --cpu

COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/validate-cached-models.sh /usr/local/bin/validate-cached-models.sh
COPY docker/extra_model_paths.yaml /etc/runpod/extra_model_paths.yaml.template

RUN chmod +x /entrypoint.sh /usr/local/bin/validate-cached-models.sh

# Override the base image CMD (["/start.sh"]) with the cache validation gate,
# which execs /start.sh only after the selected models are available.
CMD ["/entrypoint.sh"]
