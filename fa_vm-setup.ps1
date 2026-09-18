<#
.SYNOPSIS
    Hybrid Worker VM preparation for the Zero Trust Assessment.
    Run by the Azure Custom Script Extension (as SYSTEM) at deploy time.
    Installs: PowerShell 7 (latest LTS), Visual C++ Redistributable x64,
    and all required PowerShell modules machine-wide.
    Idempotent - safe to re-run.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Allow TLS 1.2 and (where supported) TLS 1.3
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13 }
catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
$Log = 'C:\Windows\Temp\zt-vm-setup.log'
Start-Transcript -Path $Log -Append

function Get-FileWithRetry {
    param([string]$Uri, [string]$OutFile, [int]$Attempts = 5)
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            Write-Output "Downloading ($i/$Attempts): $Uri"
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
            if ((Get-Item $OutFile).Length -gt 0) { return }
            throw 'Downloaded file is empty.'
        }
        catch {
            Write-Output "  Attempt $i failed: $($_.Exception.Message)"
            # Fallback method on the later attempts
            if ($i -ge 3) {
                try {
                    Write-Output '  Retrying with WebClient...'
                    (New-Object System.Net.WebClient).DownloadFile($Uri, $OutFile)
                    if ((Get-Item $OutFile -ErrorAction SilentlyContinue).Length -gt 0) { return }
                }
                catch { Write-Output "  WebClient also failed: $($_.Exception.Message)" }
            }
            if ($i -eq $Attempts) { throw "Failed to download $Uri after $Attempts attempts." }
            Start-Sleep -Seconds (10 * $i)
        }
    }
}

# ---------------------------------------------------------------------------
# 1. PowerShell 7 (MSI, machine-wide)
# ---------------------------------------------------------------------------
if (-not (Test-Path 'C:\Program Files\PowerShell\7\pwsh.exe')) {
    Write-Output 'Installing PowerShell 7...'
    $Msi = 'C:\Windows\Temp\pwsh7.msi'
    # Pinned version (fewer redirects than /latest/, deterministic installs).
    # Update the version here when a new LTS is adopted.
    Get-FileWithRetry -Uri 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/PowerShell-7.4.6-win-x64.msi' -OutFile $Msi
    Start-Process msiexec.exe -ArgumentList "/i `"$Msi`" /qn /norestart ADD_PATH=1" -Wait
    Remove-Item $Msi -Force
} else { Write-Output 'PowerShell 7 already installed.' }

# ---------------------------------------------------------------------------
# 2. Visual C++ Redistributable x64 (required by the assessment engine)
# ---------------------------------------------------------------------------
$VcInstalled = Test-Path 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
if (-not $VcInstalled) {
    Write-Output 'Installing Visual C++ Redistributable...'
    $Vc = 'C:\Windows\Temp\vc_redist.x64.exe'
    Get-FileWithRetry -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $Vc
    Start-Process $Vc -ArgumentList '/install /quiet /norestart' -Wait
    Remove-Item $Vc -Force
} else { Write-Output 'VC++ Redistributable already installed.' }

# ---------------------------------------------------------------------------
# 3. PowerShell 7 modules (machine-wide)
#    Written to a real .ps1 file and invoked with -File. Passing a large
#    command as a quoted string is fragile and can silently do nothing.
# ---------------------------------------------------------------------------
$Ps7Modules = @(
    'PSFramework'
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.Beta.Teams'
    'Az.Accounts'
    'Az.KeyVault'
    'Az.Storage'
    'ExchangeOnlineManagement'
    'ZeroTrustAssessment'
)

$Ps7ScriptPath = 'C:\Windows\Temp\zt-install-modules.ps1'
$Ps7Lines = @(
    '$ErrorActionPreference = ''Stop'''
    '$ProgressPreference = ''SilentlyContinue'''
    '[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12'
    'Write-Output "PS7 module install starting. PSVersion: $($PSVersionTable.PSVersion)"'
    'if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {'
    '    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null'
    '}'
    'Set-PSRepository -Name PSGallery -InstallationPolicy Trusted'
)
foreach ($m in $Ps7Modules) {
    $Ps7Lines += "if (Get-Module -ListAvailable -Name '$m') { Write-Output '$m already present.' }"
    $Ps7Lines += "else { Write-Output 'Installing $m ...'; Install-Module -Name '$m' -Scope AllUsers -Force -AllowClobber; Write-Output '$m installed.' }"
}
$Ps7Lines += 'Write-Output "PS7 module install finished."'

Set-Content -Path $Ps7ScriptPath -Value $Ps7Lines -Encoding UTF8

Write-Output "Running PS7 module installation (this takes several minutes)..."
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -ExecutionPolicy Bypass -File $Ps7ScriptPath
$Ps7Exit = $LASTEXITCODE
Write-Output "PS7 module installer exit code: $Ps7Exit"
if ($Ps7Exit -ne 0) { throw "PowerShell 7 module installation failed with exit code $Ps7Exit - see $Log" }

# ---------------------------------------------------------------------------
# 4. Windows PowerShell 5.1-only modules (SharePoint Online, AIP)
# ---------------------------------------------------------------------------
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
foreach ($m in 'Microsoft.Online.SharePoint.PowerShell', 'AIPService') {
    if (-not (Get-Module -ListAvailable $m)) {
        Write-Output "Installing $m (WinPS 5.1)..."
        Install-Module $m -Scope AllUsers -Force -AllowClobber
    } else { Write-Output "$m already present (WinPS 5.1)." }
}

# ---------------------------------------------------------------------------
# 5. VERIFY - never report success unless the modules are genuinely present
# ---------------------------------------------------------------------------
Write-Output "`nVerifying installed modules..."
$VerifyPath = 'C:\Windows\Temp\zt-verify-modules.ps1'
@(
    '$names = @(''' + ($Ps7Modules -join "','") + ''')'
    '$missing = @()'
    'foreach ($n in $names) {'
    '    $m = Get-Module -ListAvailable -Name $n | Select-Object -First 1'
    '    if ($m) { Write-Output ("  OK      {0} {1}" -f $m.Name, $m.Version) }'
    '    else    { Write-Output ("  MISSING {0}" -f $n); $missing += $n }'
    '}'
    'if ($missing) { Write-Error ("Missing modules: " + ($missing -join '', '')); exit 2 }'
) | Set-Content -Path $VerifyPath -Encoding UTF8

& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -ExecutionPolicy Bypass -File $VerifyPath
if ($LASTEXITCODE -ne 0) {
    throw "One or more required PowerShell 7 modules are missing. The assessment cannot run. See $Log for details."
}

foreach ($m in 'Microsoft.Online.SharePoint.PowerShell','AIPService') {
    if (Get-Module -ListAvailable -Name $m) { Write-Output "  OK      $m (WinPS 5.1)" }
    else { Write-Output "  WARNING $m missing - SharePoint/AIP pillars will be skipped" }
}

Write-Output 'VM preparation complete.'
Stop-Transcript
