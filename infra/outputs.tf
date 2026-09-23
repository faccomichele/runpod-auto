output "volume_id" {
  description = "Attach this to the serverless endpoint: Endpoint -> Manage -> Edit -> Advanced -> Network Volumes."
  value       = runpod_network_volume.models.id
}

output "volume_data_center" {
  description = "Data center the volume lives in; endpoint workers must run here."
  value       = runpod_network_volume.models.data_center_id
}
