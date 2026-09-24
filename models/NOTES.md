# NOTES

## Cached repository inventory

The worker validates the files in the private Hugging Face model repository,
not the source URLs in the manifest. Keep the repository tree and both copies
of `models/manifest.json` synchronized:

```text
models/<dest>
```

Use local files to populate exact manifest metadata before uploading them:

```powershell
$file = Get-Item .\models\checkpoints\my_model.safetensors
$file.Length
Get-FileHash $file -Algorithm SHA256
```

The resulting byte count belongs in `size_bytes`; the hash belongs in
`sha256`. Set `CACHED_MODELS_VERIFY_SHA=true` on the endpoint when auditing
the complete cached repository. The runtime does not use `url` or `auth` to
download replacements.
