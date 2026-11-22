<#
.SYNOPSIS
  Runs Terraform for the Bumpy stack with settings from infra/.env.

.EXAMPLE
  .\tf.ps1 bootstrap   # once: state storage, stack resource group, GitHub OIDC identities
  .\tf.ps1 plan        # main stack: show what would change
  .\tf.ps1 apply       # main stack: create / update
  .\tf.ps1 output      # main stack outputs (URLs, names)
  .\tf.ps1 destroy     # main stack: delete everything after the hackathon
  .\tf.ps1 fix-ingest-storage   # only the post-apply clean-up of the function app's host storage setting

  Windows PowerShell 5.1 or PowerShell 7 (`pwsh`, also on macOS: `pwsh ./tf.ps1 plan`).
#>
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('bootstrap', 'init', 'plan', 'apply', 'output', 'destroy', 'fix-ingest-storage')]
  [string]$Command,

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$envFile = Join-Path $root '.env'

function Import-DotEnv {
  if (-not (Test-Path $envFile)) {
    throw "Missing infra/.env. Copy infra/.env.example to infra/.env and fill it in."
  }
  foreach ($raw in Get-Content $envFile) {
    $line = $raw.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    $i = $line.IndexOf('=')
    if ($i -lt 1) { continue }
    $key = $line.Substring(0, $i).Trim()
    $value = $line.Substring($i + 1).Trim()
    if ($value.Length -ge 2 -and $value.StartsWith("'") -and $value.EndsWith("'")) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    if ($value -eq '') {
      Remove-Item -Path "Env:$key" -ErrorAction SilentlyContinue
    } else {
      Set-Item -Path "Env:$key" -Value $value
    }
  }
}

function Assert-Set([string[]]$Names) {
  $missing = $Names | Where-Object { -not [Environment]::GetEnvironmentVariable($_) }
  if ($missing) { throw "Fill these in infra/.env first: $($missing -join ', ')" }
}

function Set-DotEnvValue([string]$Key, [string]$Value) {
  $lines = [System.Collections.Generic.List[string]](Get-Content $envFile)
  $idx = -1
  for ($n = 0; $n -lt $lines.Count; $n++) { if ($lines[$n] -match "^\s*$Key\s*=") { $idx = $n } }
  if ($idx -ge 0) { $lines[$idx] = "$Key=$Value" } else { $lines.Add("$Key=$Value") }
  [System.IO.File]::WriteAllLines($envFile, $lines, (New-Object System.Text.UTF8Encoding $false))
}

function Invoke-Tf {
  & terraform @args
  if ($LASTEXITCODE -ne 0) { throw "terraform $($args -join ' ') failed (exit $LASTEXITCODE)" }
}

function Initialize-Main {
  Assert-Set @('TFSTATE_RESOURCE_GROUP', 'TFSTATE_STORAGE_ACCOUNT', 'TFSTATE_CONTAINER', 'TFSTATE_KEY')
  Invoke-Tf "-chdir=$root/main" init -input=false `
    "-backend-config=resource_group_name=$env:TFSTATE_RESOURCE_GROUP" `
    "-backend-config=storage_account_name=$env:TFSTATE_STORAGE_ACCOUNT" `
    "-backend-config=container_name=$env:TFSTATE_CONTAINER" `
    "-backend-config=key=$env:TFSTATE_KEY"
}

# azurerm 4.x writes a key-based `AzureWebJobsStorage=...;AccountKey=;...` into the Flex Consumption app's
# settings on every create or update, even with identity-based storage (terraform-provider-azurerm#29149).
# Storage keys are off, so the host can't start with it. Delete it; the AzureWebJobsStorage__* identity
# settings from Terraform stay. Safe to run any time (it does nothing when the setting isn't there).
function Repair-IngestHostStorage {
  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Warning "az is not on PATH, so the ingest function's AzureWebJobsStorage setting was not checked. Install the Azure CLI and run: .\tf.ps1 fix-ingest-storage"
    return
  }
  $app = (& terraform "-chdir=$root/main" output -raw ingest_function_name) | Select-Object -Last 1
  $rg = (& terraform "-chdir=$root/main" output -raw resource_group) | Select-Object -Last 1
  if ($LASTEXITCODE -ne 0 -or -not $app -or -not $rg) {
    Write-Warning "No ingest function in the Terraform outputs yet; nothing to fix."
    return
  }
  $names = @(az functionapp config appsettings list --name $app --resource-group $rg --query '[].name' -o tsv)
  if ($LASTEXITCODE -ne 0) { throw "Could not read the app settings of $app (az login? right subscription?)" }
  $names = $names | ForEach-Object { $_.Trim() }
  if ($names -contains 'AzureWebJobsStorage') {
    Write-Host "Removing the key-based AzureWebJobsStorage setting from $app (provider bug, see infra/README.md)." -ForegroundColor Yellow
    az functionapp config appsettings delete --name $app --resource-group $rg --setting-names AzureWebJobsStorage --output none
    if ($LASTEXITCODE -ne 0) { throw "Could not delete AzureWebJobsStorage from $app" }
  }
  $missing = @('AzureWebJobsStorage__accountName', 'AzureWebJobsStorage__credential', 'AzureWebJobsStorage__clientId') |
    Where-Object { $names -notcontains $_ }
  if ($missing) { throw "$app is missing $($missing -join ', '): run .\tf.ps1 apply again." }
  Write-Host "$app uses identity-based host storage only." -ForegroundColor Green
}

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
  # $IsMacOS / $IsLinux exist only in PowerShell 7; in Windows PowerShell 5.1 they are $null.
  $hint = 'winget install Hashicorp.Terraform'
  if ($IsMacOS) { $hint = 'brew tap hashicorp/tap; brew install hashicorp/tap/terraform' }
  elseif ($IsLinux) { $hint = 'see https://developer.hashicorp.com/terraform/install' }
  throw "terraform is not on PATH. Install it with: $hint"
}

Import-DotEnv
Assert-Set @('ARM_SUBSCRIPTION_ID', 'ARM_TENANT_ID')

switch ($Command) {
  'bootstrap' {
    Invoke-Tf "-chdir=$root/bootstrap" init -input=false
    Invoke-Tf "-chdir=$root/bootstrap" apply @Rest
    # Windows PowerShell 5.1 parses piped lines one by one, so join the JSON into one string first.
    $json = (& terraform "-chdir=$root/bootstrap" output -json) -join "`n"
    if ($LASTEXITCODE -ne 0 -or -not $json.Trim() -or $json.Trim() -eq '{}') {
      throw "Bootstrap has no outputs; the apply above did not finish."
    }
    $out = $json | ConvertFrom-Json
    Set-DotEnvValue 'TFSTATE_RESOURCE_GROUP' $out.tfstate_resource_group.value
    Set-DotEnvValue 'TFSTATE_STORAGE_ACCOUNT' $out.tfstate_storage_account.value
    Set-DotEnvValue 'TFSTATE_CONTAINER' $out.tfstate_container.value
    Write-Host "`nState settings written to infra/.env." -ForegroundColor Green
    Write-Host "GitHub repo variables (Settings > Secrets and variables > Actions > Variables):" -ForegroundColor Green
    $out.github_variables.value.PSObject.Properties | ForEach-Object { Write-Host ("  {0} = {1}" -f $_.Name, $_.Value) }
  }
  'init' { Initialize-Main }
  'plan' {
    Assert-Set @('TF_VAR_alert_email')
    Initialize-Main
    Invoke-Tf "-chdir=$root/main" plan @Rest
  }
  'apply' {
    Assert-Set @('TF_VAR_alert_email')
    Initialize-Main
    Invoke-Tf "-chdir=$root/main" apply @Rest
    Repair-IngestHostStorage
  }
  'fix-ingest-storage' {
    Initialize-Main
    Repair-IngestHostStorage
  }
  'output' {
    Initialize-Main
    Invoke-Tf "-chdir=$root/main" output @Rest
  }
  'destroy' {
    Assert-Set @('TF_VAR_alert_email')
    Initialize-Main
    Invoke-Tf "-chdir=$root/main" destroy @Rest
  }
}
