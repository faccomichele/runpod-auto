# Optional: Terraform-managed network volume

The serverless endpoint in this project is deployed and updated by
[RunPod's GitHub integration](../docs/runpod-setup.md), not by Terraform, so
Terraform here only manages the **network volume** that stores model weights.

## Usage

```bash
cd infra
export RUNPOD_API_KEY="..."      # or uncomment the provider block in providers.tf
terraform init
terraform apply -var="data_center_id=US-KS-2" -var="volume_size_gb=100"
```

Then attach the volume id from the output to your endpoint in the console:
**Endpoint -> Manage -> Edit Endpoint -> Advanced -> Network Volumes**.

If you prefer not to use Terraform, create the volume in the RunPod console
under **Storage -> New Network Volume** with the same settings.

## Notes

- The volume pins the endpoint to its data center; pick one that has your GPU
  types and (for easy pre-warming) supports the network volume S3 API.
- Volume size can be increased later but never decreased.
- The provider is the community
  [`decentralized-infrastructure/runpod`](https://github.com/decentralized-infrastructure/terraform-provider-runpod)
  provider. It also has a `runpod_endpoint` resource, but it does not manage
  endpoint environment variables or templates, which is why the endpoint is
  created through the GitHub integration instead.
