# NOTES

## How to get file details

```sh
$url="https://civitai.com/api/v1/model-versions/0000001"
$temp = curl.exe -s "$url" | ConvertFrom-Json -AsHashtable; $temp.files | ForEach-Object { [pscustomobject]@{ id = $_.id; name = $_.name; sizeKB = $_.sizeKB; bytes = [long]($_.sizeKB * 1024) } } | Format-List; $temp.files | ForEach-Object { $_.hashes | ConvertTo-Json -Compress }

$url="https://huggingface.co/org/repo_name/resolve/main/split_files/vae/file.safetensors"
curl.exe -sIL "$url" | Select-String -Pattern '^content-length'
```
