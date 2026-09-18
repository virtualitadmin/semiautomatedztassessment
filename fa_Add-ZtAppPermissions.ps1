<#
.SYNOPSIS
    Configures an app registration for the automated Zero Trust Assessment:
    - Microsoft Graph APPLICATION permissions (always)
    - Office 365 Exchange Online: Exchange.ManageAsApp   (-IncludeExchangeOnline)
    - Azure Rights Management: Application.Read.All      (-IncludeAipService)
    - Entra directory roles for the service principal    (-AssignGlobalReader,
                                                          -AssignSharePointAdministrator)
    Optionally grants tenant-wide admin consent for all of the above.

.DESCRIPTION
    - Permission names are resolved dynamically against each API's service
      principal, so no role GUIDs are hard-coded.
    - Merges with the app's existing permissions (nothing is removed).
    - With -GrantAdminConsent, creates the app role assignments on the app's
      service principal - the API equivalent of the portal's
      "Grant admin consent" button.

.NOTES
    Run interactively in PowerShell 7 as a Global Administrator or
    Privileged Role Administrator.
    Requires modules: Microsoft.Graph.Authentication, Microsoft.Graph.Applications.
    Role assignment additionally uses Microsoft.Graph.Identity.Governance-free
    direct Graph calls (Invoke-MgGraphRequest), no extra module needed.

.EXAMPLE
    # Everything needed for -Services Graph, Azure, ExchangeOnline:
    .\Add-ZtAppPermissions.ps1 -AppId "1111...5555" -IncludeExchangeOnline `
        -AssignGlobalReader -GrantAdminConsent

.EXAMPLE
    # Full coverage prep (adds AIP permission and SharePoint Administrator):
    .\Add-ZtAppPermissions.ps1 -AppId "1111...5555" -IncludeExchangeOnline `
        -IncludeAipService -AssignGlobalReader -AssignSharePointAdministrator `
        -GrantAdminConsent
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$AppId,                          # Application (client) ID of the app registration

    [switch]$IncludeExchangeOnline,          # Add Exchange.ManageAsApp (Office 365 Exchange Online)
    [switch]$IncludeAipService,              # Add Application.Read.All (Azure Rights Management)
    [switch]$AssignGlobalReader,             # Assign Global Reader directory role to the SP
    [switch]$AssignSharePointAdministrator,  # Assign SharePoint Administrator role to the SP
    [switch]$GrantAdminConsent               # Grant tenant-wide admin consent for API permissions
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# APIs and the permissions to request from each
# ---------------------------------------------------------------------------
$GraphPermissions = @(
    'CopilotPackages.Read.All'
    'CustomSecAttributeAssignment.Read.All'
    'LifecycleWorkflows-Workflow.Read.All'
    'PrivilegedAssignmentSchedule.Read.AzureADGroup'
    'PrivilegedEligibilitySchedule.Read.AzureADGroup'
    'RoleManagement.Read.All'
    'SecurityAlert.Read.All'
    'SecurityEvents.Read.All'
    'SecurityIdentitiesHealth.Read.All'
    'SecurityIdentitiesSensors.Read.All'
    'SecurityIncident.Read.All'
    'ThreatHunting.Read.All'
    'UserAuthenticationMethod.Read.All'
    'Application.Read.All'
    'AuditLog.Read.All'
    'CrossTenantInformation.ReadBasic.All'
    'DeviceManagementApps.Read.All'
    'DeviceManagementConfiguration.Read.All'
    'DeviceManagementManagedDevices.Read.All'
    'DeviceManagementRBAC.Read.All'
    'DeviceManagementServiceConfig.Read.All'
    'Directory.Read.All'
    'DirectoryRecommendations.Read.All'
    'EntitlementManagement.Read.All'
    'IdentityRiskEvent.Read.All'
    'IdentityRiskyUser.Read.All'
    'IdentityRiskyServicePrincipal.Read.All'
    'NetworkAccess.Read.All'
    'Policy.Read.All'
    'Policy.Read.ConditionalAccess'
    'Policy.Read.PermissionGrant'
    'PrivilegedAccess.Read.AzureAD'
    'Reports.Read.All'
) | Select-Object -Unique

# Well-known first-party API App IDs (identical in every tenant)
$Apis = @(
    @{ Name = 'Microsoft Graph'
       AppId = '00000003-0000-0000-c000-000000000000'
       Permissions = $GraphPermissions }
)
if ($IncludeExchangeOnline) {
    $Apis += @{ Name = 'Office 365 Exchange Online'
                AppId = '00000002-0000-0ff1-ce00-000000000000'
                Permissions = @('Exchange.ManageAsApp') }
}
if ($IncludeAipService) {
    $Apis += @{ Name = 'Azure Rights Management Services'
                AppId = '00000012-0000-0000-c000-000000000000'
                Permissions = @('Application.Read.All') }
}

# Entra built-in role template IDs (identical in every tenant)
$RolesToAssign = @()
if ($AssignGlobalReader) {
    $RolesToAssign += @{ Name = 'Global Reader'
                         TemplateId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451' }
}
if ($AssignSharePointAdministrator) {
    $RolesToAssign += @{ Name = 'SharePoint Administrator'
                         TemplateId = 'f28a1f50-f6e7-4571-818b-6a12f2af6b6c' }
}

# ---------------------------------------------------------------------------
# 1. Connect (interactive, delegated). Role assignment needs an extra scope.
# ---------------------------------------------------------------------------
$Scopes = @('Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All')
if ($RolesToAssign.Count -gt 0) { $Scopes += 'RoleManagement.ReadWrite.Directory' }
Connect-MgGraph -Scopes $Scopes -NoWelcome

# ---------------------------------------------------------------------------
# 2. Look up the app registration
# ---------------------------------------------------------------------------
$App = Get-MgApplication -Filter "appId eq '$AppId'"
if (-not $App) { throw "No app registration found with AppId $AppId" }
Write-Host "App registration: $($App.DisplayName)" -ForegroundColor Cyan

# The app's own service principal (created if missing; needed for consent/roles)
$AppSp = Get-MgServicePrincipal -Filter "appId eq '$AppId'"
if (-not $AppSp -and ($GrantAdminConsent -or $RolesToAssign.Count -gt 0)) {
    Write-Host "Service principal not found - creating it..." -ForegroundColor Yellow
    $AppSp = New-MgServicePrincipal -AppId $AppId
}

# ---------------------------------------------------------------------------
# 3. Per API: resolve names -> app roles, merge into RequiredResourceAccess
# ---------------------------------------------------------------------------
$Existing  = @($App.RequiredResourceAccess)
$NotFound  = @()
$AllResolved = @{}   # ResourceSp.Id -> list of roles (for consent step)
$NewRequired = @()

foreach ($Api in $Apis) {
    Write-Host "`nProcessing API: $($Api.Name)" -ForegroundColor Cyan
    $ResourceSp = Get-MgServicePrincipal -Filter "appId eq '$($Api.AppId)'"
    if (-not $ResourceSp) {
        Write-Warning "Service principal for '$($Api.Name)' not found in this tenant - skipping."
        continue
    }

    $Resolved = @()
    foreach ($Name in $Api.Permissions) {
        $Role = $ResourceSp.AppRoles | Where-Object {
            $_.Value -eq $Name -and $_.AllowedMemberTypes -contains 'Application'
        }
        if ($Role) {
            $Resolved += $Role
            Write-Host ("  Resolved {0} -> {1}" -f $Name, $Role.Id)
        }
        else {
            $NotFound += "$($Api.Name): $Name"
            Write-Warning "  '$Name' not found as an Application role on $($Api.Name) - skipping."
        }
    }
    if ($Resolved.Count -gt 0) { $AllResolved[$ResourceSp.Id] = @{ Sp = $ResourceSp; Roles = $Resolved } }

    # merge with any existing entry for this API
    $ExistingEntry  = $Existing | Where-Object { $_.ResourceAppId -eq $Api.AppId }
    $ExistingAccess = @(); if ($ExistingEntry) { $ExistingAccess = @($ExistingEntry.ResourceAccess) }
    $NewAccess = foreach ($Role in $Resolved) {
        if (-not ($ExistingAccess | Where-Object { $_.Id -eq $Role.Id })) {
            @{ Id = $Role.Id; Type = 'Role' }
        }
    }
    $NewRequired += @{ ResourceAppId = $Api.AppId; ResourceAccess = @($ExistingAccess) + @($NewAccess) }
    Write-Host "  $(@($NewAccess).Count) new, $(@($ExistingAccess).Count) already present." -ForegroundColor Green
}

# keep entries for any APIs this script doesn't manage
$ManagedAppIds = $Apis.AppId
$Untouched = $Existing | Where-Object { $_.ResourceAppId -notin $ManagedAppIds }

Update-MgApplication -ApplicationId $App.Id -RequiredResourceAccess (@($Untouched) + @($NewRequired))
Write-Host "`nApp registration updated." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Optionally grant tenant-wide admin consent (all APIs)
# ---------------------------------------------------------------------------
if ($GrantAdminConsent) {
    $CurrentAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $AppSp.Id -All
    foreach ($Entry in $AllResolved.Values) {
        foreach ($Role in $Entry.Roles) {
            if ($CurrentAssignments | Where-Object { $_.AppRoleId -eq $Role.Id -and $_.ResourceId -eq $Entry.Sp.Id }) {
                Write-Host "  Consent already granted: $($Entry.Sp.DisplayName) / $($Role.Value)"
                continue
            }
            $null = New-MgServicePrincipalAppRoleAssignment `
                -ServicePrincipalId $AppSp.Id `
                -PrincipalId        $AppSp.Id `
                -ResourceId         $Entry.Sp.Id `
                -AppRoleId          $Role.Id
            Write-Host "  Consent granted: $($Entry.Sp.DisplayName) / $($Role.Value)" -ForegroundColor Green
        }
    }
    Write-Host "`nAdmin consent complete." -ForegroundColor Green
}
else {
    Write-Host "`nNOTE: Permissions were added but NOT consented." -ForegroundColor Yellow
    Write-Host "Re-run with -GrantAdminConsent, or press 'Grant admin consent' in the portal." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 5. Optionally assign Entra directory roles to the service principal
# ---------------------------------------------------------------------------
foreach ($RoleDef in $RolesToAssign) {
    Write-Host "`nAssigning directory role: $($RoleDef.Name)" -ForegroundColor Cyan
    $ExistingAssignment = Invoke-MgGraphRequest -Method GET -Uri `
        "v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($AppSp.Id)' and roleDefinitionId eq '$($RoleDef.TemplateId)'"
    if ($ExistingAssignment.value.Count -gt 0) {
        Write-Host "  Already assigned." -ForegroundColor Green
        continue
    }
    $null = Invoke-MgGraphRequest -Method POST -Uri "v1.0/roleManagement/directory/roleAssignments" -Body @{
        principalId      = $AppSp.Id
        roleDefinitionId = $RoleDef.TemplateId
        directoryScopeId = '/'
    }
    Write-Host "  Assigned." -ForegroundColor Green
}

if ($NotFound) {
    Write-Host "`nPermissions that could not be resolved:" -ForegroundColor Yellow
    $NotFound | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}

Disconnect-MgGraph | Out-Null
