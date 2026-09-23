# Optional: Terraform-managed network volume

The serverless endpoint in this project is deployed and updated by
[RunPod's GitHub integration](../docs/runpod-setup.md), not by Terraform, so
Terraform here only manages the **network volume** that stores model weights.

## Usage

```bash
# Option A (recommended): the wrapper loads the repo-root .env
pwsh -File scripts/tf.ps1 init
pwsh -File scripts/tf.ps1 apply -var="data_center_id=US-KS-2" -var="volume_size_gb=100"

# Option B: source .env yourself (bash), then plain terraform
cd infra
set -a; . ../.env; set +a
terraform init
terraform apply -var="data_center_id=US-KS-2" -var="volume_size_gb=100"
```

Copy `.env.example` to `.env` first (from the repo root) and fill in
`RUNPOD_API_KEY`.

Then attach the volume id from the output to your endpoint in the console:
**Endpoint -> Manage -> Edit Endpoint -> Advanced -> Network Volumes**.

If you prefer not to use Terraform, create the volume in the RunPod console
under **Storage -> New Network Volume** with the same settings.

## Teardown / ephemeral sessions

`terraform destroy` permanently deletes the volume and every model on it.
Detach the volume from the endpoint first (**Endpoint -> Manage -> Edit ->
Advanced -> Network Volumes**), so the endpoint does not keep pointing at a
deleted volume, then:

```bash
terraform -chdir=infra destroy
```

On Windows, `scripts/session-up.ps1` and `scripts/session-down.ps1` wrap
`apply`/`destroy` (typed confirmation, printed attach/detach steps).

Billing, cost examples, and state edge cases (`state rm` after a manual delete;
importing an existing volume) live in
[docs/runpod-setup.md -> Session lifecycle](../docs/runpod-setup.md#10-session-lifecycle--teardown-ephemeral-volume).

If the volume was already deleted outside Terraform, drop it from state:

```bash
terraform -chdir=infra state rm runpod_network_volume.models
```

## Notes

- The volume pins the endpoint to its data center; pick one that has your GPU
  types and (for easy pre-warming) supports the network volume S3 API.
- Volume size can be increased later but never decreased.
- The provider is the community
  [`decentralized-infrastructure/runpod`](https://github.com/decentralized-infrastructure/terraform-provider-runpod)
  provider. It also has a `runpod_endpoint` resource, but it does not manage
  endpoint environment variables or templates, which is why the endpoint is
  created through the GitHub integration instead.
