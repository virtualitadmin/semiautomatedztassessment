<#
.SYNOPSIS
    STEP 1 OF 3 - Zero Trust Assessment bootstrap (Microsoft Entra).
    Creates the app registration, grants all required permissions with admin
    consent, assigns directory roles, and writes config.json for step 2.

.DESCRIPTION
    Run ONCE per customer tenant, interactively, as a GLOBAL ADMINISTRATOR.
    Safe to re-run: existing app, permissions and roles are detected and kept.

.PARAMETER AppDisplayName
    Name for the app registration. Reused if it already exists.

.PARAMETER ConfigFile
    Where to write the configuration for the next step. Default: ./config.json

.PARAMETER NoSharePointAndAip
    Skip the Azure Rights Management permission and the SharePoint
    Administrator role. Use this if you only want the Graph, Azure, Exchange
    and Security & Compliance pillars.

.EXAMPLE
    .\fa_Bootstrap-ZtApp.ps1 -AppDisplayName "Zero Trust Assessment - Contoso"

.NOTES
    Requires PowerShell 7 and:
        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
        Install-Module Microsoft.Graph.Applications   -Scope CurrentUser -Force
#>

[CmdletBinding()]
param(
    [string]$AppDisplayName = 'Zero Trust Assessment',
    [string]$ConfigFile     = './config.json',

    # Full pillar coverage is the default: adds the Azure Rights Management
    # permission and the SharePoint Administrator role. Use -NoSharePointAndAip
    # to set up Graph/Azure/Exchange only.
    [switch]$NoSharePointAndAip
)

$ErrorActionPreference = 'Stop'

function Write-Step   { param($m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Good   { param($m) Write-Host "  $m" -ForegroundColor Green }
function Write-Info   { param($m) Write-Host "  $m" }
function Write-Warn2  { param($m) Write-Host "  $m" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Permission sets
# ---------------------------------------------------------------------------
$GraphPermissions = @(
    'CopilotPackages.Read.All','CustomSecAttributeAssignment.Read.All'
    'LifecycleWorkflows-Workflow.Read.All','PrivilegedAssignmentSchedule.Read.AzureADGroup'
    'PrivilegedEligibilitySchedule.Read.AzureADGroup','RoleManagement.Read.All'
    'SecurityAlert.Read.All','SecurityEvents.Read.All','SecurityIdentitiesHealth.Read.All'
    'SecurityIdentitiesSensors.Read.All','SecurityIncident.Read.All','ThreatHunting.Read.All'
    'UserAuthenticationMethod.Read.All','Application.Read.All','AuditLog.Read.All'
    'CrossTenantInformation.ReadBasic.All','DeviceManagementApps.Read.All'
    'DeviceManagementConfiguration.Read.All','DeviceManagementManagedDevices.Read.All'
    'DeviceManagementRBAC.Read.All','DeviceManagementServiceConfig.Read.All'
    'Directory.Read.All','DirectoryRecommendations.Read.All','EntitlementManagement.Read.All'
    'IdentityRiskEvent.Read.All','IdentityRiskyUser.Read.All','IdentityRiskyServicePrincipal.Read.All'
    'NetworkAccess.Read.All','Policy.Read.All','Policy.Read.ConditionalAccess'
    'Policy.Read.PermissionGrant','PrivilegedAccess.Read.AzureAD','Reports.Read.All'
) | Select-Object -Unique

$Apis = @(
    @{ Name = 'Microsoft Graph';            AppId = '00000003-0000-0000-c000-000000000000'; Permissions = $GraphPermissions }
    @{ Name = 'Office 365 Exchange Online'; AppId = '00000002-0000-0ff1-ce00-000000000000'; Permissions = @('Exchange.ManageAsApp') }
)
$RolesToAssign = @(
    @{ Name = 'Global Reader'; TemplateId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451' }
)
if (-not $NoSharePointAndAip) {
    $Apis += @{ Name = 'Azure Rights Management Services'; AppId = '00000012-0000-0000-c000-000000000000'; Permissions = @('Application.Read.All') }
    $RolesToAssign += @{ Name = 'SharePoint Administrator'; TemplateId = 'f28a1f50-f6e7-4571-818b-6a12f2af6b6c' }
}

# ---------------------------------------------------------------------------
Write-Step 'Checking prerequisites'
foreach ($m in 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications') {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        throw "Module '$m' is not installed. Run:  Install-Module $m -Scope CurrentUser -Force"
    }
}
Write-Good 'Required modules present.'

Write-Step 'Signing in to Microsoft Entra'
Write-Info 'A browser window will open - sign in as a Global Administrator.'
Connect-MgGraph -Scopes 'Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All','RoleManagement.ReadWrite.Directory' -NoWelcome
$Context = Get-MgContext
Write-Good "Signed in to tenant $($Context.TenantId) as $($Context.Account)"

# ---------------------------------------------------------------------------
Write-Step 'App registration'
$App = Get-MgApplication -Filter "displayName eq '$AppDisplayName'" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($App) {
    Write-Good "Existing app found: $($App.DisplayName) ($($App.AppId))"
}
else {
    $App = New-MgApplication -DisplayName $AppDisplayName -SignInAudience 'AzureADMyOrg'
    Write-Good "Created app registration: $AppDisplayName ($($App.AppId))"
    Start-Sleep -Seconds 10   # let the directory replicate before we use it
}

$AppSp = Get-MgServicePrincipal -Filter "appId eq '$($App.AppId)'" -ErrorAction SilentlyContinue
if (-not $AppSp) {
    $AppSp = New-MgServicePrincipal -AppId $App.AppId
    Write-Good "Created service principal ($($AppSp.Id))"
    Start-Sleep -Seconds 10
}
else {
    Write-Good "Existing service principal ($($AppSp.Id))"
}

# ---------------------------------------------------------------------------
Write-Step 'Resolving and adding API permissions'
$Existing     = @($App.RequiredResourceAccess)
$NewRequired  = @()
$AllResolved  = @{}
$NotFound     = @()

foreach ($Api in $Apis) {
    Write-Info "API: $($Api.Name)"
    $ResourceSp = Get-MgServicePrincipal -Filter "appId eq '$($Api.AppId)'" -ErrorAction SilentlyContinue
    if (-not $ResourceSp) { Write-Warn2 "  not present in this tenant - skipped"; continue }

    $Resolved = @()
    foreach ($Name in $Api.Permissions) {
        $Role = $ResourceSp.AppRoles | Where-Object { $_.Value -eq $Name -and $_.AllowedMemberTypes -contains 'Application' }
        if ($Role) { $Resolved += $Role } else { $NotFound += "$($Api.Name): $Name" }
    }
    Write-Info "  resolved $($Resolved.Count) of $($Api.Permissions.Count) permissions"
    if ($Resolved.Count -gt 0) { $AllResolved[$ResourceSp.Id] = @{ Sp = $ResourceSp; Roles = $Resolved } }

    $ExistingEntry  = $Existing | Where-Object { $_.ResourceAppId -eq $Api.AppId }
    $ExistingAccess = @(); if ($ExistingEntry) { $ExistingAccess = @($ExistingEntry.ResourceAccess) }
    $NewAccess = foreach ($Role in $Resolved) {
        if (-not ($ExistingAccess | Where-Object { $_.Id -eq $Role.Id })) { @{ Id = $Role.Id; Type = 'Role' } }
    }
    $NewRequired += @{ ResourceAppId = $Api.AppId; ResourceAccess = @($ExistingAccess) + @($NewAccess) }
}

$ManagedAppIds = $Apis.AppId
$Untouched = $Existing | Where-Object { $_.ResourceAppId -notin $ManagedAppIds }
Update-MgApplication -ApplicationId $App.Id -RequiredResourceAccess (@($Untouched) + @($NewRequired))
Write-Good 'Permissions written to the app registration.'

# ---------------------------------------------------------------------------
Write-Step 'Granting admin consent'
$Current = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $AppSp.Id -All
$Granted = 0; $Already = 0
foreach ($Entry in $AllResolved.Values) {
    foreach ($Role in $Entry.Roles) {
        if ($Current | Where-Object { $_.AppRoleId -eq $Role.Id -and $_.ResourceId -eq $Entry.Sp.Id }) { $Already++; continue }
        try {
            $null = New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $AppSp.Id `
                -PrincipalId $AppSp.Id -ResourceId $Entry.Sp.Id -AppRoleId $Role.Id
            $Granted++
        }
        catch { Write-Warn2 "  could not grant $($Role.Value): $($_.Exception.Message)" }
    }
}
Write-Good "Consent granted: $Granted new, $Already already in place."

# ---------------------------------------------------------------------------
Write-Step 'Assigning directory roles'
foreach ($RoleDef in $RolesToAssign) {
    $Uri = "v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($AppSp.Id)' and roleDefinitionId eq '$($RoleDef.TemplateId)'"
    $Assigned = Invoke-MgGraphRequest -Method GET -Uri $Uri
    if ($Assigned.value.Count -gt 0) { Write-Good "$($RoleDef.Name): already assigned"; continue }
    try {
        $null = Invoke-MgGraphRequest -Method POST -Uri 'v1.0/roleManagement/directory/roleAssignments' -Body @{
            principalId = $AppSp.Id; roleDefinitionId = $RoleDef.TemplateId; directoryScopeId = '/'
        }
        Write-Good "$($RoleDef.Name): assigned"
    }
    catch { Write-Warn2 "$($RoleDef.Name): could not assign - $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
Write-Step 'Writing configuration file'

$Config = [ordered]@{
    _README                  = 'Edit the values marked EDIT ME, then run fa_Deploy-ZtAssessment.ps1 -ConfigFile config.json'
    tenantId                 = $Context.TenantId
    appDisplayName           = $App.DisplayName
    appClientId              = $App.AppId
    servicePrincipalObjectId = $AppSp.Id

    resourceGroup            = 'zt-assessment-rg'
    location                 = 'uksouth'
    baseName                 = 'ztassess'

    vmSize                   = 'Standard_D2s_v3'      # EDIT ME - must be allowed by customer policy
    vmAdminUsername          = 'ztadmin'

    containerName            = 'ztassessment'
    reportRetentionDays      = 90
    services                 = @('Graph','Azure','ExchangeOnline','SecurityCompliance','SharePointOnline','AipService')
    scheduleStartTime        = (Get-Date).AddDays(7).ToString('yyyy-MM-ddT02:00:00+00:00')
    scheduleIntervalMonths   = 1

    baseTags = [ordered]@{
        'created by' = 'EDIT ME'
        environment  = 'production'
        service      = 'security-assessment'
        sme          = 'EDIT ME'
        'used-by'    = 'security-team'
    }
    vmExtraTags = [ordered]@{
        Application      = 'Zero Trust Assessment'
        'backup-policy'  = 'none'
        'bcp-priority'   = 'low'
        Owner            = 'EDIT ME'
        'patch-schedule' = 'default'
        'power-profile'  = 'always-on'
    }
}

if (Test-Path $ConfigFile) {
    $Backup = "$ConfigFile.bak"
    Copy-Item $ConfigFile $Backup -Force
    Write-Warn2 "Existing config backed up to $Backup"
}
$Config | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigFile -Encoding UTF8
Write-Good "Configuration written to $ConfigFile"

# ---------------------------------------------------------------------------
Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " BOOTSTRAP COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Tenant ID                   : $($Context.TenantId)"
Write-Host " Application (client) ID     : $($App.AppId)"
Write-Host " Service principal object ID : $($AppSp.Id)"
Write-Host ""
Write-Host " NEXT STEPS:" -ForegroundColor Cyan
Write-Host "  1. Open $ConfigFile and replace every 'EDIT ME' value."
Write-Host "     Check vmSize is permitted by the customer's Azure Policy."
Write-Host "  2. Upload config.json and the solution files to Azure Cloud Shell."
Write-Host "  3. Run:  ./fa_Deploy-ZtAssessment.ps1 -ConfigFile config.json"
Write-Host ""

if ($NotFound) {
    Write-Warn2 'Permissions that could not be resolved in this tenant:'
    $NotFound | ForEach-Object { Write-Warn2 "  - $_" }
    Write-Warn2 'These are usually licence-dependent and can normally be ignored.'
}

Disconnect-MgGraph | Out-Null
