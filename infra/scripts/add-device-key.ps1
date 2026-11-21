<#
.SYNOPSIS
  Creates a device key for one phone (or the replay tool) and stores only its SHA-256 hash in Key Vault.

.DESCRIPTION
  The secret `device-key-hashes` holds a JSON object {"<deviceId>": "<sha256 hex of key>", ...}.
  The ingest function compares x-device-key in constant time (plan §5) and reloads the secret by
  itself within a minute when it sees an unknown key.
  A key may only send data whose deviceId is the name it is stored under, so -DeviceId must be the
  app's Device ID (Settings -> Device ID). Use -DeviceId replay for the replay tool: that key may
  send any replay-... device ID.
  The plain key is printed once: type it into the app's upload settings. It is not stored anywhere.

  -RenameFrom moves an existing entry to a new name and keeps its key (no new key is printed), for
  entries created under a free-form name before keys were bound to the device ID.

.EXAMPLE
  .\add-device-key.ps1 -DeviceId 8C3F1A2B-1234-4ABC-9DEF-0123456789AB

.EXAMPLE
  .\add-device-key.ps1 -DeviceId 8C3F1A2B-1234-4ABC-9DEF-0123456789AB -RenameFrom iphone14pro-mihai
#>
param(
  [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9._-]{1,64}$')][string]$DeviceId,
  [ValidatePattern('^[A-Za-z0-9._-]{1,64}$')][string]$RenameFrom,
  [string]$VaultName,
  [string]$SecretName = 'device-key-hashes'
)

$ErrorActionPreference = 'Stop'

if (-not $VaultName) {
  $VaultName = (& (Join-Path $PSScriptRoot '..\tf.ps1') output -raw key_vault_name | Select-Object -Last 1)
}

$current = @{}
# On the first key the secret doesn't exist yet and az writes an error to stderr. With
# ErrorActionPreference 'Stop', Windows PowerShell 5.1 turns redirected native stderr into a
# terminating error, so relax it for this one call and decide by the exit code instead.
$ErrorActionPreference = 'Continue'
$existing = az keyvault secret show --vault-name $VaultName --name $SecretName --query value -o tsv 2>$null
$showExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($showExit -eq 0 -and $existing) {
  ($existing | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $current[$_.Name] = $_.Value }
} elseif ($showExit -ne 0) {
  # Distinguish "no secret yet" from "can't reach the vault" (wrong name, no rights, not logged in).
  $ErrorActionPreference = 'Continue'
  $names = az keyvault secret list --vault-name $VaultName --query "[].name" -o tsv 2>$null
  $listExit = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  if ($listExit -ne 0) {
    throw "Can't read Key Vault '$VaultName'. Check 'az login' and that your object ID is in TF_VAR_admin_object_ids (Key Vault Secrets Officer)."
  }
  if ($names -contains $SecretName) {
    throw "Secret '$SecretName' exists but couldn't be read; not overwriting it."
  }
}
if ($RenameFrom) {
  # Hashtable keys are case-insensitive: renaming to the same name in other case would delete it.
  if ($RenameFrom -eq $DeviceId) { throw "-RenameFrom and -DeviceId are the same name." }
  if (-not $current.ContainsKey($RenameFrom)) { throw "No entry named '$RenameFrom' in $VaultName/$SecretName." }
  if ($current.ContainsKey($DeviceId)) { throw "An entry named '$DeviceId' already exists; not overwriting it." }
  $current[$DeviceId] = $current[$RenameFrom]
  $current.Remove($RenameFrom)
  $key = $null
} else {
  $bytes = New-Object byte[] 32
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $key = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')

  $sha = [System.Security.Cryptography.SHA256]::Create()
  $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)) | ForEach-Object { $_.ToString('x2') })
  $current[$DeviceId] = $hash
}

$tmp = New-TemporaryFile
try {
  [System.IO.File]::WriteAllText($tmp, ($current | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
  az keyvault secret set --vault-name $VaultName --name $SecretName --file $tmp --encoding utf-8 --output none
  if ($LASTEXITCODE -ne 0) { throw "az keyvault secret set failed" }
} finally {
  Remove-Item $tmp -Force
}

if ($RenameFrom) {
  Write-Host "Renamed '$RenameFrom' to '$DeviceId' in $VaultName/$SecretName; the phone keeps its key." -ForegroundColor Green
} else {
  Write-Host "Stored hash for '$DeviceId' in $VaultName/$SecretName." -ForegroundColor Green
  Write-Host "Device key (enter it in the app; shown only now):"
  Write-Host $key
}
