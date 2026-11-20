<#
.SYNOPSIS
  Deploys the ingest function from a laptop (CI does the same on merge: .github/workflows/deploy-ingest.yml).

.DESCRIPTION
  Zips the app (forward-slash paths, which Linux needs; Windows PowerShell's Compress-Archive writes
  backslashes) and uploads it with a remote build, so Azure installs requirements.txt for Linux.
  Reads the app and resource group names from the Terraform outputs unless given.

.EXAMPLE
  .\deploy.ps1
#>
param(
  [string]$AppName,
  [string]$ResourceGroup
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$tf = Join-Path $here '..\..\infra\tf.ps1'

if (-not $AppName) { $AppName = (& $tf output -raw ingest_function_name | Select-Object -Last 1) }
if (-not $ResourceGroup) { $ResourceGroup = (& $tf output -raw resource_group | Select-Object -Last 1) }

$files = @('function_app.py', 'host.json', 'requirements.txt') +
  (Get-ChildItem (Join-Path $here 'ingest_core') -Filter *.py | ForEach-Object { "ingest_core/$($_.Name)" })

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zipPath = Join-Path ([IO.Path]::GetTempPath()) "ingest-$([guid]::NewGuid()).zip"
$zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
  foreach ($f in $files) {
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $here $f), $f)
  }
} finally {
  $zip.Dispose()
}

try {
  Write-Host "Deploying $($files.Count) files to $AppName ($ResourceGroup)..."
  az functionapp deployment source config-zip --resource-group $ResourceGroup --name $AppName `
    --src $zipPath --build-remote true --output none
  if ($LASTEXITCODE -ne 0) { throw "deployment failed" }
} finally {
  Remove-Item $zipPath -Force
}

$base = (& $tf output -raw ingest_base_url | Select-Object -Last 1)
Write-Host "Deployed. Ingest URL: $base" -ForegroundColor Green
