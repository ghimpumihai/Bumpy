<#
.SYNOPSIS
  Creates a device key for one phone (or the replay tool) and stores only its SHA-256 hash in Key Vault.

.DESCRIPTION
  The secret `device-key-hashes` holds a JSON object {"<deviceId>": "<sha256 hex of key>", ...}.
  The ingest function loads it once at start-up and compares x-device-key in constant time (plan §5).
  Restart the function app after adding a key so it reloads the secret.
  The plain key is printed once: type it into the app's upload settings. It is not stored anywhere.

.EXAMPLE
  .\add-device-key.ps1 -DeviceId iphone14pro-mihai
#>
param(
  [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9._-]{1,64}$')][string]$DeviceId,
  [string]$VaultName,
  [string]$SecretName = 'device-key-hashes'
)

$ErrorActionPreference = 'Stop'

if (-not $VaultName) {
  $VaultName = (& (Join-Path $PSScriptRoot '..\tf.ps1') output -raw key_vault_name | Select-Object -Last 1)
}

$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$key = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')

$sha = [System.Security.Cryptography.SHA256]::Create()
$hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)) | ForEach-Object { $_.ToString('x2') })

$current = @{}
$existing = az keyvault secret show --vault-name $VaultName --name $SecretName --query value -o tsv 2>$null
if ($LASTEXITCODE -eq 0 -and $existing) {
  ($existing | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $current[$_.Name] = $_.Value }
}
$current[$DeviceId] = $hash

$tmp = New-TemporaryFile
try {
  [System.IO.File]::WriteAllText($tmp, ($current | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
  az keyvault secret set --vault-name $VaultName --name $SecretName --file $tmp --encoding utf-8 --output none
  if ($LASTEXITCODE -ne 0) { throw "az keyvault secret set failed" }
} finally {
  Remove-Item $tmp -Force
}

Write-Host "Stored hash for '$DeviceId' in $VaultName/$SecretName." -ForegroundColor Green
Write-Host "Device key (enter it in the app; shown only now):"
Write-Host $key
