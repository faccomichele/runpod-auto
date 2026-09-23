variable "runpod_api_key" {
  description = "RunPod API key. Optional: export RUNPOD_API_KEY instead."
  type        = string
  sensitive   = true
  default     = null
}

variable "volume_name" {
  description = "Name of the network volume that stores ComfyUI models."
  type        = string
  default     = "comfyui-models"
}

variable "volume_size_gb" {
  description = "Volume size in GB. Can be increased later but never decreased. ~100 GB fits SDXL/FLUX; add ~40 GB for Wan 2.2 I2V. For per-session (ephemeral) volumes see docs/runpod-setup.md."
  type        = number
  default     = 100
}

variable "data_center_id" {
  description = "RunPod data center id. The endpoint's workers must run in the same data center as the volume. Prefer DCs that support the network volume S3 API and carry your GPU types."
  type        = string
  default     = "US-KS-2"
}
