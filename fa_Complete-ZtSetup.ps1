<#
.SYNOPSIS
    STEP 3 OF 3 - Finishes the Zero Trust Assessment setup and proves it works.

.DESCRIPTION
    Run after fa_Deploy-ZtAssessment.ps1 completes. It:
      1. Reads the certificate generated in Key Vault by the deployment
      2. Attaches its public key to the app registration (via Microsoft Graph)
      3. Grants the service principal Reader on the subscription(s)
      4. Optionally starts the orchestrator and watches it end to end

    Safe to re-run. Step 2 requires an Entra sign-in with rights to update the
    app registration (Application Administrator or Global Administrator).

.PARAMETER ConfigFile
    config.json, as used by the previous steps.

.PARAMETER SubscriptionIds
    Subscriptions to grant Reader on. Defaults to the current subscription.

.PARAMETER SkipTestRun
    Do the wiring but don't start an assessment.

.PARAMETER TestRunTimeoutMinutes
    How long to wait for the test run before giving up watching (the job
    continues regardless).

.EXAMPLE
    ./fa_Complete-ZtSetup.ps1 -ConfigFile config.json
#>

[CmdletBinding()]
param(
    [string]$ConfigFile = './config.json',
    [string[]]$SubscriptionIds,
    [switch]$SkipTestRun,
    [switch]$Force,
    [int]$TestRunTimeoutMinutes = 120
)

$ErrorActionPreference = 'Stop'

function Write-Step  { param($m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Good  { param($m) Write-Host "  $m" -ForegroundColor Green }
function Write-Info  { param($m) Write-Host "  $m" }
function Write-Warn2 { param($m) Write-Host "  $m" -ForegroundColor Yellow }
function Fail        { param($m) Write-Host "`nERROR: $m" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $ConfigFile)) { Fail "Config file '$ConfigFile' not found." }
$Cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json

$DeployName = 'ztassessment'

# ---------------------------------------------------------------------------
Write-Step 'Reading deployment outputs'

$OutJson = az deployment group show -g $Cfg.resourceGroup -n $DeployName --query properties.outputs -o json 2>$null
if (-not $OutJson) { Fail "Could not read deployment '$DeployName' in '$($Cfg.resourceGroup)'. Did fa_Deploy-ZtAssessment.ps1 finish successfully?" }
$Out = $OutJson | ConvertFrom-Json

$CerBase64   = $Out.certificateCerBase64.value
$Thumbprint  = $Out.certificateThumbprint.value
$StorageName = $Out.storageAccountName.value
$AutoAccount = $Out.automationAccountName.value
$WorkerGroup = $Out.hybridWorkerGroup.value
$VmName      = $Out.vmNameOut.value

if (-not $CerBase64) { Fail 'The deployment did not return a certificate. Check the deployment completed fully.' }
Write-Good "Certificate thumbprint: $Thumbprint"
Write-Good "Automation account: $AutoAccount | VM: $VmName"

# ---------------------------------------------------------------------------
Write-Step 'Attaching the certificate to the app registration'

foreach ($m in 'Microsoft.Graph.Authentication','Microsoft.Graph.Applications') {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Fail "Module '$m' is not installed. Run: Install-Module $m -Scope CurrentUser -Force"
    }
}

Write-Info 'Signing in to Microsoft Entra (Application Administrator or Global Administrator)...'
Connect-MgGraph -Scopes 'Application.ReadWrite.All' -TenantId $Cfg.tenantId -NoWelcome

$App = Get-MgApplication -Filter "appId eq '$($Cfg.appClientId)'"
if (-not $App) { Fail "App registration $($Cfg.appClientId) not found in tenant $($Cfg.tenantId)." }

$CertBytes = [Convert]::FromBase64String($CerBase64)
$Cert      = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CertBytes)

$Existing = @($App.KeyCredentials)
$AlreadyThere = $Existing | Where-Object {
    $_.CustomKeyIdentifier -and (([BitConverter]::ToString($_.CustomKeyIdentifier) -replace '-','') -eq $Thumbprint)
}

if ($AlreadyThere) {
    Write-Good 'Certificate is already attached - nothing to do.'
}
else {
    # Microsoft Graph never returns existing key material on read (the Key
    # property comes back null), so existing certificates cannot be re-sent
    # and WILL be replaced by this update. Make that explicit.
    $Others = $Existing | Where-Object { $_.Type -eq 'AsymmetricX509Cert' }
    if ($Others) {
        Write-Warn2 "This app registration already has $($Others.Count) certificate(s) attached:"
        foreach ($o in $Others) {
            $tp = if ($o.CustomKeyIdentifier) { [BitConverter]::ToString($o.CustomKeyIdentifier) -replace '-','' } else { '(unknown)' }
            Write-Warn2 "    $($o.DisplayName) | thumbprint $tp | expires $($o.EndDateTime)"
        }
        Write-Warn2 'Microsoft Graph does not allow existing certificates to be preserved when'
        Write-Warn2 'adding a new one this way - they will be REPLACED by the new certificate.'
        if (-not $Force) {
            $Answer = Read-Host 'Continue and replace them? (yes/no)'
            if ($Answer -notmatch '^(y|yes)$') {
                Fail 'Cancelled. Re-run with -Force to replace, or attach the certificate manually in the portal.'
            }
        }
    }

    $NewCreds = @(
        @{
            type        = 'AsymmetricX509Cert'
            usage       = 'Verify'
            key         = $CertBytes
            displayName = "ZT Assessment (Key Vault) $Thumbprint"
        }
    )
    Update-MgApplication -ApplicationId $App.Id -KeyCredentials $NewCreds
    Write-Good "Certificate attached (valid until $($Cert.NotAfter.ToString('yyyy-MM-dd')))."
    Write-Info 'Allowing 30s for directory replication...'
    Start-Sleep -Seconds 30
}

Disconnect-MgGraph | Out-Null

# ---------------------------------------------------------------------------
Write-Step 'Granting Azure read access'

if (-not $SubscriptionIds) {
    $SubscriptionIds = @((az account show --query id -o tsv))
}
foreach ($SubId in $SubscriptionIds) {
    $Scope = "/subscriptions/$SubId"
    $Have = az role assignment list --assignee $Cfg.servicePrincipalObjectId --role Reader --scope $Scope --query "[].id" -o tsv 2>$null
    if ($Have) {
        Write-Good "Reader already assigned on $SubId"
    }
    else {
        az role assignment create --assignee-object-id $Cfg.servicePrincipalObjectId `
            --assignee-principal-type ServicePrincipal --role Reader --scope $Scope -o none
        if ($LASTEXITCODE -eq 0) { Write-Good "Reader assigned on $SubId" }
        else { Write-Warn2 "Could not assign Reader on $SubId - you may need User Access Administrator." }
    }
}

# ---------------------------------------------------------------------------
Write-Step 'Checking the worker VM software'

$LogOut = az vm run-command invoke -g $Cfg.resourceGroup -n $VmName --command-id RunPowerShellScript `
    --scripts "Get-Content C:\Windows\Temp\zt-vm-setup.log -Tail 6" --query "value[0].message" -o tsv 2>$null

if ($LogOut -match 'VM preparation complete') { Write-Good 'VM setup completed successfully.' }
elseif ($LogOut) {
    Write-Warn2 'VM setup log does not show completion. Last lines:'
    $LogOut -split "`n" | Select-Object -Last 6 | ForEach-Object { Write-Warn2 "    $_" }
}
else {
    Write-Warn2 'Could not read the VM setup log (the VM may be deallocated - this is normal after a run).'
}

# ---------------------------------------------------------------------------
if ($SkipTestRun) {
    Write-Host "`nSetup complete. Test run skipped (-SkipTestRun)." -ForegroundColor Green
    exit 0
}

Write-Step 'Starting a test assessment'
Write-Info 'This starts the VM, runs the assessment, then shuts the VM down.'
Write-Info "Expect 45-90 minutes. You can close this window - the job continues in Azure."

$Job = az automation runbook start --automation-account-name $AutoAccount -g $Cfg.resourceGroup `
    --name 'ZeroTrustAssessment-Orchestrator' -o json | ConvertFrom-Json
if (-not $Job.jobId) { Fail 'Could not start the orchestrator runbook.' }
$JobId = $Job.jobId
Write-Good "Job started: $JobId"

$Deadline = (Get-Date).AddMinutes($TestRunTimeoutMinutes)
$Last = ''
while ((Get-Date) -lt $Deadline) {
    Start-Sleep -Seconds 60
    $Status = az automation job show --automation-account-name $AutoAccount -g $Cfg.resourceGroup `
        --job-id $JobId --query status -o tsv 2>$null
    if ($Status -and $Status -ne $Last) {
        Write-Info "$(Get-Date -Format 'HH:mm:ss')  status: $Status"
        $Last = $Status
    }
    if ($Status -in 'Completed','Failed','Stopped','Suspended') { break }
}

Write-Host ''
switch ($Last) {
    'Completed' {
        Write-Host '============================================================' -ForegroundColor Green
        Write-Host ' SUCCESS - the assessment ran end to end' -ForegroundColor Green
        Write-Host '============================================================' -ForegroundColor Green
        Write-Host " Reports are in storage account : $StorageName"
        Write-Host " Container                      : $($Cfg.containerName)"
        Write-Host ''
        Write-Host ' Download the latest report with:' -ForegroundColor Cyan
        Write-Host "   az storage blob list --account-name $StorageName -c $($Cfg.containerName) --auth-mode login --query `"[].name`" -o tsv"
        Write-Host ''
        Write-Host " The monthly schedule is already active - nothing more to do."
    }
    'Failed' {
        Write-Warn2 'The test run failed. View the job output for details:'
        Write-Info "  az automation job output show --automation-account-name $AutoAccount -g $($Cfg.resourceGroup) --job-id $JobId"
        Write-Info '  Common causes: certificate not yet replicated (wait 10 min and re-run),'
        Write-Info '  missing Graph consent, or Reader role not yet propagated.'
        Write-Warn2 "Check the VM was shut down: az vm get-instance-view -g $($Cfg.resourceGroup) -n $VmName --query instanceView.statuses"
    }
    default {
        Write-Warn2 "Still running after $TestRunTimeoutMinutes minutes (status: $Last)."
        Write-Info  'This is normal for large tenants. Check progress in the portal, or:'
        Write-Info  "  az automation job show --automation-account-name $AutoAccount -g $($Cfg.resourceGroup) --job-id $JobId --query status -o tsv"
    }
}
