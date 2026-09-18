<#
.SYNOPSIS
    STEP 2 OF 3 - Deploys the Zero Trust Assessment Azure resources.

.DESCRIPTION
    Run in Azure Cloud Shell (PowerShell) from a folder containing:
        config.json (from fa_Bootstrap-ZtApp.ps1)
        main.bicep
        vm-setup.ps1
        ztassessment-runbook-cert.ps1
        ztassessment-orchestrator.ps1

    Performs everything between bootstrap and a running deployment:
      1. Creates the resource group with the required tags
      2. Creates a private staging storage account
      3. Uploads the three scripts and the PowerShell 7 installer
      4. Generates read-only SAS links for each
      5. Patches vm-setup.ps1 to fetch the installer from storage
      6. Writes main.parameters.json
      7. Runs the ARM deployment

    Safe to re-run: existing resources are reused, the deployment is incremental.

.PARAMETER ConfigFile
    Path to config.json produced by fa_Bootstrap-ZtApp.ps1.

.PARAMETER VmAdminPassword
    Local administrator password for the worker VM. Prompted for if omitted.

.PARAMETER WhatIf2
    Preview the deployment without creating the Azure resources
    (staging storage IS still created, as the deployment needs the links).

.EXAMPLE
    ./fa_Deploy-ZtAssessment.ps1 -ConfigFile config.json
#>

[CmdletBinding()]
param(
    [string]$ConfigFile = './config.json',
    [securestring]$VmAdminPassword,
    [switch]$WhatIf2,
    [string]$PwshMsiUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi',
    [int]$SasValidDays = 30
)

$ErrorActionPreference = 'Stop'

function Write-Step  { param($m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Good  { param($m) Write-Host "  $m" -ForegroundColor Green }
function Write-Info  { param($m) Write-Host "  $m" }
function Write-Warn2 { param($m) Write-Host "  $m" -ForegroundColor Yellow }
function Fail        { param($m) Write-Host "`nERROR: $m" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
Write-Step 'Validating inputs'

if (-not (Test-Path $ConfigFile)) { Fail "Config file '$ConfigFile' not found. Run fa_Bootstrap-ZtApp.ps1 first." }
$Cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json

$RequiredFiles = @('fa_main.bicep','fa_vm-setup.ps1','fa_ztassessment-runbook-cert.ps1','fa_ztassessment-orchestrator.ps1')
foreach ($f in $RequiredFiles) {
    if (-not (Test-Path "./$f")) { Fail "Required file './$f' not found in the current folder." }
}
Write-Good "All $($RequiredFiles.Count) solution files present."

# Check for unedited placeholders
$Unedited = @()
foreach ($set in 'baseTags','vmExtraTags') {
    $Cfg.$set.PSObject.Properties | Where-Object { $_.Value -eq 'EDIT ME' } | ForEach-Object { $Unedited += "$set.$($_.Name)" }
}
if ($Unedited) {
    Fail ("These values still say 'EDIT ME' in $ConfigFile - fill them in first:`n  " + ($Unedited -join "`n  "))
}

if (-not $Cfg.appClientId -or -not $Cfg.servicePrincipalObjectId) {
    Fail "config.json is missing appClientId or servicePrincipalObjectId. Re-run fa_Bootstrap-ZtApp.ps1."
}

# Schedule must be in the future
if ([datetime]$Cfg.scheduleStartTime -lt (Get-Date).AddMinutes(30)) {
    Fail "scheduleStartTime ($($Cfg.scheduleStartTime)) must be at least 30 minutes in the future. Edit $ConfigFile."
}

if (-not $VmAdminPassword) {
    $VmAdminPassword = Read-Host -AsSecureString "Enter a password for the VM local administrator ($($Cfg.vmAdminUsername))"
}
$PlainPwd = [System.Net.NetworkCredential]::new('', $VmAdminPassword).Password
if ($PlainPwd.Length -lt 12) { Fail 'VM password must be at least 12 characters (Azure requirement).' }

# Azure context
try { $Sub = az account show --query "{id:id,name:name}" -o json | ConvertFrom-Json }
catch { Fail "Not signed in to Azure. Run 'az login' (or use Cloud Shell)." }
Write-Good "Subscription: $($Sub.name) ($($Sub.id))"

# ---------------------------------------------------------------------------
Write-Step "Resource group: $($Cfg.resourceGroup)"

$TagArgs = @()
$Cfg.baseTags.PSObject.Properties | ForEach-Object { $TagArgs += "$($_.Name)=$($_.Value)" }

$RgExists = (az group exists --name $Cfg.resourceGroup) -eq 'true'
if ($RgExists) {
    Write-Good 'Already exists - updating tags.'
    az group update --name $Cfg.resourceGroup --set "tags={}" -o none 2>$null
    az tag update --resource-id "/subscriptions/$($Sub.id)/resourceGroups/$($Cfg.resourceGroup)" --operation Merge --tags @TagArgs -o none
}
else {
    az group create --name $Cfg.resourceGroup --location $Cfg.location --tags @TagArgs -o none
    if ($LASTEXITCODE -ne 0) { Fail 'Could not create the resource group. Check your permissions and the tag values against customer policy.' }
    Write-Good 'Created.'
}

# ---------------------------------------------------------------------------
Write-Step 'Staging storage account'

$StagingName = $Cfg.stagingAccountName
if (-not $StagingName) {
    $StagingName = "ztstg$((New-Guid).ToString('N').Substring(0,12))"
}

$Exists = az storage account show -g $Cfg.resourceGroup -n $StagingName -o none 2>$null; $ok = ($LASTEXITCODE -eq 0)
if (-not $ok) {
    Write-Info "Creating $StagingName ..."
    az storage account create -g $Cfg.resourceGroup -n $StagingName --sku Standard_LRS --kind StorageV2 `
        --min-tls-version TLS1_2 --allow-blob-public-access false --tags @TagArgs -o none
    if ($LASTEXITCODE -ne 0) { Fail "Could not create staging storage account '$StagingName'." }
}
Write-Good "Staging account: $StagingName"

$Key = az storage account keys list -g $Cfg.resourceGroup -n $StagingName --query "[0].value" -o tsv --only-show-errors
if (-not $Key) { Fail 'Could not read the staging storage account key (needs Owner or Storage Account Contributor).' }

foreach ($c in 'scripts','installers') {
    az storage container create --account-name $StagingName --account-key $Key --name $c -o none 2>$null
}
Write-Good 'Containers ready: scripts, installers'

# ---------------------------------------------------------------------------
Write-Step 'PowerShell 7 installer'

$MsiLocal = './pwsh7.msi'
$MsiBlob  = 'PowerShell-7-win-x64.msi'
$MsiThere = az storage blob exists --account-name $StagingName --account-key $Key -c installers -n $MsiBlob --query exists -o tsv

if ($MsiThere -eq 'true') {
    Write-Good 'Already uploaded - skipping download.'
}
else {
    Write-Info 'Downloading (about 100 MB, one-off)...'
    try { Invoke-WebRequest -Uri $PwshMsiUrl -OutFile $MsiLocal -UseBasicParsing }
    catch { Fail "Could not download the PowerShell installer from $PwshMsiUrl - $($_.Exception.Message)" }
    az storage blob upload --account-name $StagingName --account-key $Key -c installers -f $MsiLocal -n $MsiBlob --overwrite -o none
    Remove-Item $MsiLocal -Force -ErrorAction SilentlyContinue
    Write-Good 'Uploaded to staging storage.'
}

$Expiry = (Get-Date).AddDays($SasValidDays).ToUniversalTime().ToString('yyyy-MM-ddTHH:mmZ')
function New-BlobSas {
    param($Container, $Blob)
    $u = az storage blob generate-sas --account-name $StagingName --account-key $Key `
            -c $Container -n $Blob --permissions r --expiry $Expiry --full-uri -o tsv --only-show-errors
    if (-not $u) { Fail "Could not generate a SAS link for $Container/$Blob." }
    return $u.Trim('"')
}
$MsiSas = New-BlobSas -Container 'installers' -Blob $MsiBlob

# ---------------------------------------------------------------------------
Write-Step 'Preparing and uploading scripts'

# Patch vm-setup.ps1 so the VM pulls the MSI from storage, not GitHub.
# Match the PowerShell download URL itself, whatever cmdlet fetches it, so an
# older copy of the script is still patched correctly.
$SetupRaw = Get-Content './fa_vm-setup.ps1' -Raw
$UrlPattern = "'https://github\.com/PowerShell/PowerShell/releases/[^']*'"
$Patched = [regex]::Replace($SetupRaw, $UrlPattern, "'$MsiSas'", 1)

if ($Patched -eq $SetupRaw) {
    if ($SetupRaw -match [regex]::Escape($MsiSas)) {
        Write-Good 'vm-setup.ps1 already points at the staged installer.'
    }
    else {
        Fail @"
Could not find the PowerShell installer URL in vm-setup.ps1, so the VM would
try to download it from the internet and fail.

Expected to find a line containing:
    'https://github.com/PowerShell/PowerShell/releases/...'

You are probably using an outdated copy of vm-setup.ps1. Download the latest
version and upload it again, then re-run this script.
"@
    }
}
else {
    Write-Good 'vm-setup.ps1 patched to use staged installer.'
}

# Sanity check: the script must also have the retry helper, added in the
# current version - older copies fail on transient download errors.
if ($Patched -notmatch 'Get-FileWithRetry') {
    Write-Warn2 'This copy of vm-setup.ps1 has no download retry logic (older version).'
    Write-Warn2 'It will probably still work, but the latest version is more reliable.'
}
$PatchedPath = './fa_vm-setup.staged.ps1'
Set-Content -Path $PatchedPath -Value $Patched -Encoding UTF8

$Uploads = @(
    @{ Local = $PatchedPath;                        Blob = 'vm-setup.ps1' }
    @{ Local = './fa_ztassessment-runbook-cert.ps1';   Blob = 'ztassessment-runbook-cert.ps1' }
    @{ Local = './fa_ztassessment-orchestrator.ps1';   Blob = 'ztassessment-orchestrator.ps1' }
)
foreach ($u in $Uploads) {
    az storage blob upload --account-name $StagingName --account-key $Key -c scripts -f $u.Local -n $u.Blob --overwrite -o none
    if ($LASTEXITCODE -ne 0) { Fail "Upload failed: $($u.Blob)" }
}
Write-Good 'All three scripts uploaded.'

$VmSetupSas      = New-BlobSas -Container 'scripts' -Blob 'vm-setup.ps1'
$RunbookSas      = New-BlobSas -Container 'scripts' -Blob 'ztassessment-runbook-cert.ps1'
$OrchestratorSas = New-BlobSas -Container 'scripts' -Blob 'ztassessment-orchestrator.ps1'
Write-Good "SAS links generated (valid until $Expiry)."

# ---------------------------------------------------------------------------
Write-Step 'Writing deployment parameters'

$Params = [ordered]@{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = [ordered]@{
        baseName                 = @{ value = $Cfg.baseName }
        tenantId                 = @{ value = $Cfg.tenantId }
        appClientId              = @{ value = $Cfg.appClientId }
        servicePrincipalObjectId = @{ value = $Cfg.servicePrincipalObjectId }
        runbookContentUri        = @{ value = $RunbookSas }
        vmSetupScriptUri         = @{ value = $VmSetupSas }
        orchestratorContentUri   = @{ value = $OrchestratorSas }
        containerName            = @{ value = $Cfg.containerName }
        reportRetentionDays      = @{ value = $Cfg.reportRetentionDays }
        services                 = @{ value = @($Cfg.services) }
        scheduleStartTime        = @{ value = $Cfg.scheduleStartTime }
        scheduleIntervalMonths   = @{ value = $Cfg.scheduleIntervalMonths }
        vmSize                   = @{ value = $Cfg.vmSize }
        vmAdminUsername          = @{ value = $Cfg.vmAdminUsername }
        baseTags                 = @{ value = $Cfg.baseTags }
        vmExtraTags              = @{ value = $Cfg.vmExtraTags }
    }
}
$ParamPath = './fa_main.parameters.generated.json'
$Params | ConvertTo-Json -Depth 8 | Set-Content -Path $ParamPath -Encoding UTF8
Write-Good "Written: $ParamPath"
Write-Warn2 "$ParamPath contains SAS access links - don't share it or commit it to source control."

# Remember the staging account for re-runs
$Cfg | Add-Member -NotePropertyName stagingAccountName -NotePropertyValue $StagingName -Force
$Cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigFile -Encoding UTF8

# ---------------------------------------------------------------------------
Write-Step 'Deploying Azure resources'
Write-Info 'This takes 15-25 minutes. Leave the window open.'

$DeployName = 'ztassessment'
$CommonArgs = @(
    'deployment','group','create',
    '--resource-group', $Cfg.resourceGroup,
    '--template-file', './fa_main.bicep',
    '--parameters', "@$ParamPath",
    '--parameters', "vmAdminPassword=$PlainPwd",
    '--name', $DeployName,
    '--only-show-errors'
)
if ($WhatIf2) { $CommonArgs += '--what-if'; Write-Warn2 'PREVIEW MODE - no resources will be created.' }

$Output = az @CommonArgs 2>&1
$Code = $LASTEXITCODE
$Text = ($Output | Out-String)

# Redact anything sensitive before the output is shown, logged, or pasted into
# a ticket: the VM password and the SAS tokens in the script URLs.
function Protect-Output {
    param([string]$Value)
    if ($PlainPwd) { $Value = $Value.Replace($PlainPwd, '***VM-PASSWORD-REDACTED***') }
    # SAS query strings: keep the blob path, drop the token
    $Value = [regex]::Replace($Value, '\?sv=[^"''\s]+', '?***SAS-TOKEN-REDACTED***')
    if ($Key) { $Value = $Value.Replace($Key, '***STORAGE-KEY-REDACTED***') }
    return $Value
}
$Text = Protect-Output $Text

if ($Code -ne 0) {
    Write-Host $Text
    Write-Host "`n--- What this probably means ---" -ForegroundColor Yellow
    switch -Regex ($Text) {
        'Allowed virtual machine size|SkuNotAvailable' {
            Write-Warn2 "The VM size '$($Cfg.vmSize)' is blocked by policy or unavailable in $($Cfg.location)."
            Write-Warn2 "Ask the customer which sizes are permitted, then change vmSize in $ConfigFile." }
        'RequestDisallowedByPolicy.*[Tt]ag|tag' {
            Write-Warn2 'A tag policy rejected the deployment. Check baseTags / vmExtraTags values in the config.' }
        'quota' {
            Write-Warn2 "Subscription quota reached (often Automation accounts per region). Try a different 'location' in the config, or free up quota." }
        'AuthorizationFailed|does not have authorization' {
            Write-Warn2 'Your account cannot create role assignments. You need Owner or User Access Administrator on the resource group.' }
        'MFA|multi-factor' {
            Write-Warn2 'Azure requires an MFA-authenticated session. Use Cloud Shell, or run: az account clear; az login' }
        'CustomScript.*404|does not exist' {
            Write-Warn2 'The VM could not download a script. The SAS links may have expired - just re-run this script to regenerate them.' }
        default {
            Write-Warn2 'See the error above. Re-running this script is safe and resumes where it failed.' }
    }
    exit 1
}

Write-Host $Text
Write-Good 'Deployment succeeded.'

if (-not $WhatIf2) {
    Write-Host "`n============================================================" -ForegroundColor Green
    Write-Host ' DEPLOYMENT COMPLETE' -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ' NEXT STEP:' -ForegroundColor Cyan
    Write-Host "  ./fa_Complete-ZtSetup.ps1 -ConfigFile $ConfigFile"
    Write-Host '  (attaches the certificate, grants Azure read access, runs a test)'
    Write-Host ''
}
