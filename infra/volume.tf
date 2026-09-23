# Persistent model storage for the serverless ComfyUI worker.
# The worker mounts it at /runpod-volume; a pre-warm Pod mounts it at /workspace.
resource "runpod_network_volume" "models" {
  name           = var.volume_name
  size           = var.volume_size_gb
  data_center_id = var.data_center_id
}
