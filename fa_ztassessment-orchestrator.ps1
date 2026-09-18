<#
.SYNOPSIS
    Zero Trust Assessment ORCHESTRATOR - Azure Automation Runbook
    (PowerShell 7.2+ runtime, runs in the AZURE SANDBOX - not on the worker)

.DESCRIPTION
    Point the monthly schedule at THIS runbook, not at the assessment runbook.
    It will:
      1. Start the Hybrid Worker VM (deallocated between runs to save cost)
      2. Wait for the Hybrid Worker to register and accept jobs
      3. Start the assessment runbook on the hybrid worker group and wait
      4. ALWAYS deallocate the VM afterwards, even if the assessment fails

.NOTES
    Requires on the Automation account:
      - System-assigned managed identity ENABLED
      - Managed identity roles:
          * Virtual Machine Contributor on the resource group (start/stop VM)
          * Automation Contributor on the Automation account (start runbooks)
      - Modules (runtime 7.2+): Az.Accounts, Az.Compute, Az.Automation

    Automation variables used (created by the Bicep deployment):
      - ZT-VmResourceGroup, ZT-VmName, ZT-WorkerGroup
      - ZT-AutomationAccountName, ZT-AutomationResourceGroup
#>

param(
    [string]$ContainerName = 'ztassessment',

    [object]$Services = @('Graph', 'Azure', 'ExchangeOnline', 'SecurityCompliance', 'SharePointOnline', 'AipService'),

    [string]$AssessmentRunbookName = 'ZeroTrustAssessment',

    # Minutes to wait for the worker to come online after VM start
    [int]$WorkerReadyTimeoutMinutes = 15,

    # Minutes to wait for the assessment job to finish
    [int]$AssessmentTimeoutMinutes = 240,

    # Leave the VM running afterwards (for troubleshooting)
    [switch]$SkipShutdown
)

$ErrorActionPreference = 'Stop'

# Azure Automation passes array parameters as raw command-line text, so
# normalise whatever arrives into a clean list (see the assessment runbook
# for the same handling).
$Services = @($Services) -join ',' -replace '[\[\]"'']', '' -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
if (-not $Services) { $Services = @('Graph','Azure') }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$VmResourceGroup         = Get-AutomationVariable -Name 'ZT-VmResourceGroup'
$VmName                  = Get-AutomationVariable -Name 'ZT-VmName'
$WorkerGroup             = Get-AutomationVariable -Name 'ZT-WorkerGroup'
$AutomationAccountName   = Get-AutomationVariable -Name 'ZT-AutomationAccountName'
$AutomationResourceGroup = Get-AutomationVariable -Name 'ZT-AutomationResourceGroup'

Write-Output "=== Zero Trust Assessment orchestrator ==="
Write-Output "VM: $VmName (RG: $VmResourceGroup) | Worker group: $WorkerGroup"

# ---------------------------------------------------------------------------
# Authenticate with the Automation account's managed identity
# ---------------------------------------------------------------------------
Connect-AzAccount -Identity | Out-Null
Write-Output "Connected with managed identity."

$JobId = $null

try {
    # -----------------------------------------------------------------------
    # 1. Start the VM (no-op if already running)
    # -----------------------------------------------------------------------
    $Vm = Get-AzVM -ResourceGroupName $VmResourceGroup -Name $VmName -Status
    $PowerState = ($Vm.Statuses | Where-Object Code -like 'PowerState/*').Code

    if ($PowerState -eq 'PowerState/running') {
        Write-Output "VM is already running."
    }
    else {
        Write-Output "VM state: $PowerState - starting..."
        Start-AzVM -ResourceGroupName $VmResourceGroup -Name $VmName | Out-Null
        Write-Output "VM started."
    }

    # -----------------------------------------------------------------------
    # 2. Wait for the Hybrid Worker to register
    #    A freshly started VM needs several minutes before the worker service
    #    connects and can accept jobs.
    #    NOTE: there is no Get-AzAutomationHybridWorker cmdlet - the workers
    #    inside a group are only exposed through the ARM REST API.
    # -----------------------------------------------------------------------
    $SubscriptionId = (Get-AzContext).Subscription.Id
    $WorkersUri = "/subscriptions/$SubscriptionId/resourceGroups/$AutomationResourceGroup" +
                  "/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName" +
                  "/hybridRunbookWorkerGroups/$WorkerGroup/hybridRunbookWorkers?api-version=2021-06-22"

    Write-Output "Waiting for a hybrid worker in group '$WorkerGroup' (timeout: $WorkerReadyTimeoutMinutes min)..."
    $Deadline = (Get-Date).AddMinutes($WorkerReadyTimeoutMinutes)
    $WorkerReady = $false
    $CheckFailed = $false

    while ((Get-Date) -lt $Deadline) {
        Start-Sleep -Seconds 30
        try {
            $Response = Invoke-AzRestMethod -Method GET -Path $WorkersUri
            if ($Response.StatusCode -eq 200) {
                $Workers = ($Response.Content | ConvertFrom-Json).value
                if ($Workers -and $Workers.Count -gt 0) {
                    $WorkerReady = $true
                    Write-Output "Hybrid worker registered: $($Workers[0].name)"
                    break
                }
                Write-Output "  group is empty - still waiting..."
            }
            else {
                Write-Output "  worker query returned HTTP $($Response.StatusCode) - still waiting..."
            }
        }
        catch {
            # Don't fail the run just because the status query is unavailable -
            # fall back to a time-based wait and let the job dispatch decide.
            $CheckFailed = $true
            Write-Output "  could not query workers ($($_.Exception.Message)) - will fall back to a timed wait."
            break
        }
    }

    if (-not $WorkerReady) {
        if ($CheckFailed) {
            Write-Warning "Worker status could not be confirmed. Waiting 5 minutes, then attempting the job anyway."
            Start-Sleep -Seconds 300
        }
        else {
            throw "No hybrid worker registered in group '$WorkerGroup' within $WorkerReadyTimeoutMinutes minutes. Check the VM is running and the HybridWorkerExtension is healthy."
        }
    }

    # Grace period - the worker can report present a little before it is
    # genuinely ready to take jobs.
    Write-Output "Allowing 60s grace period before dispatching the job..."
    Start-Sleep -Seconds 60

    # -----------------------------------------------------------------------
    # 3. Start the assessment runbook on the worker and wait for it
    # -----------------------------------------------------------------------
    Write-Output "Starting '$AssessmentRunbookName' on worker group '$WorkerGroup'..."
    Write-Output "  Services: $($Services -join ', ')"
    # Pass as a single comma-separated string: Azure Automation mangles array
    # parameters on the command line. The assessment runbook splits it back out.
    $Job = Start-AzAutomationRunbook `
        -ResourceGroupName    $AutomationResourceGroup `
        -AutomationAccountName $AutomationAccountName `
        -Name                 $AssessmentRunbookName `
        -RunOn                $WorkerGroup `
        -Parameters           @{ ContainerName = $ContainerName; Services = ($Services -join ',') }

    $JobId = $Job.JobId
    Write-Output "Assessment job started. Job ID: $JobId"

    $JobDeadline = (Get-Date).AddMinutes($AssessmentTimeoutMinutes)
    $Terminal = @('Completed', 'Failed', 'Stopped', 'Suspended')
    $LastStatus = ''

    while ((Get-Date) -lt $JobDeadline) {
        Start-Sleep -Seconds 60
        $JobState = Get-AzAutomationJob `
            -ResourceGroupName $AutomationResourceGroup `
            -AutomationAccountName $AutomationAccountName `
            -Id $JobId
        if ($JobState.Status -ne $LastStatus) {
            Write-Output "  Job status: $($JobState.Status)"
            $LastStatus = $JobState.Status
        }
        if ($JobState.Status -in $Terminal) { break }
    }

    if ($LastStatus -notin $Terminal) {
        # Hybrid Worker jobs have NO time limit, so a hung job would keep the
        # VM running indefinitely. Stop it before giving up.
        Write-Warning "Assessment job $JobId did not finish within $AssessmentTimeoutMinutes minutes (last status: $LastStatus). Stopping it."
        try {
            Stop-AzAutomationJob -ResourceGroupName $AutomationResourceGroup `
                -AutomationAccountName $AutomationAccountName -Id $JobId -ErrorAction Stop
            Write-Output "Assessment job stopped."
        }
        catch {
            Write-Warning "Could not stop job $JobId : $($_.Exception.Message)"
        }
        Write-Warning "NOTE: the report may still have been produced and uploaded before the job hung - check the storage container."
        throw "Assessment job $JobId exceeded the $AssessmentTimeoutMinutes minute timeout."
    }

    # Surface the assessment's own output into this job's output
    Write-Output "`n--- Assessment job output ---"
    Get-AzAutomationJobOutput `
        -ResourceGroupName $AutomationResourceGroup `
        -AutomationAccountName $AutomationAccountName `
        -Id $JobId -Stream Any |
        ForEach-Object { Write-Output $_.Summary }
    Write-Output "--- End assessment output ---`n"

    if ($LastStatus -ne 'Completed') {
        throw "Assessment job finished with status '$LastStatus'. See the job output above."
    }

    Write-Output "Assessment completed successfully."
}
finally {
    # -----------------------------------------------------------------------
    # 4. ALWAYS deallocate the VM - runs even if the assessment failed, so a
    #    bad run never leaves the VM billing.
    #    Stop-AzVM -Force DEALLOCATES (a guest OS shutdown would not).
    # -----------------------------------------------------------------------
    if ($SkipShutdown) {
        Write-Output "SkipShutdown specified - leaving the VM running."
    }
    else {
        try {
            Write-Output "Deallocating VM '$VmName'..."
            Stop-AzVM -ResourceGroupName $VmResourceGroup -Name $VmName -Force | Out-Null
            Write-Output "VM deallocated - compute charges stopped."
        }
        catch {
            Write-Warning "FAILED TO DEALLOCATE THE VM: $($_.Exception.Message)"
            Write-Warning "Deallocate '$VmName' manually to avoid unnecessary charges."
        }
    }
}

Write-Output "=== Orchestrator finished ==="
