# Zero Trust Assessment — Automated Deployment Guide

**Who this is for:** anyone who has been handed the solution files and needs to
set up the automated Zero Trust Assessment in a Microsoft tenant. No prior
knowledge of the solution is assumed.

**What you will end up with:** a monthly, hands-off security assessment. A
virtual machine switches itself on, runs the assessment, saves the report to
Azure storage, and switches itself off again.

**How long it takes:** roughly 20 minutes of your attention, plus about 90
minutes of waiting while things run.

**What you actually do:** run three scripts and edit one small settings file.

---

## Before you start

### Files you should have (eight)

| File | What it does |
|---|---|
| `fa_Bootstrap-ZtApp.ps1` | **Script 1** — sets up permissions in Microsoft Entra |
| `fa_Deploy-ZtAssessment.ps1` | **Script 2** — builds everything in Azure |
| `fa_Complete-ZtSetup.ps1` | **Script 3** — finishes the wiring and tests it |
| `fa_main.bicep` | The blueprint Script 2 uses to build Azure resources |
| `fa_vm-setup.ps1` | Installs software on the virtual machine |
| `fa_ztassessment-runbook-cert.ps1` | The assessment itself |
| `fa_ztassessment-orchestrator.ps1` | Starts the VM, runs the assessment, shuts it down |
| `fa_Add-ZtAppPermissions.ps1` | Optional — adjusts permissions later if needed |

### Access you need

- **Global Administrator** in Microsoft Entra — for Script 1 only.
- **Owner** on an Azure subscription — for Scripts 2 and 3. Contributor is
  *not* enough, because the deployment creates role assignments.

If two different people hold these, that's fine: person A runs Script 1 and
hands over `config.json`; person B runs Scripts 2 and 3.

### Three questions to ask the customer first

Each of these has blocked a deployment before. Get the answers before you start.

1. **Which virtual machine sizes are allowed** by their Azure Policy? You want
   a 2-vCPU option such as `Standard_D2s_v3`.
2. **Which tags are mandatory**, and what values are acceptable? You'll need
   values for: created by, environment, service, sme, used-by, Application,
   backup-policy, bcp-priority, Owner, patch-schedule, power-profile.
3. **Which Azure region** should this live in?

---

## Part 1 — Set up permissions (Script 1)

*Done once per customer tenant, by a Global Administrator, on a normal Windows
PC. This part cannot be automated further — granting tenant-wide permissions
deliberately requires a human to approve it.*

### 1.1 Install PowerShell 7 if you don't have it

Search the Start menu for "PowerShell 7". If it isn't there, download it from
`https://aka.ms/powershell-release` (the `.msi` file) and install with defaults.

> Do **not** use the blue "Windows PowerShell" — it's a different, older program
> and the scripts won't work in it.

### 1.2 Install the two modules the script needs

Open **PowerShell 7** and run:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
Install-Module Microsoft.Graph.Applications -Scope CurrentUser -Force
```

This takes a couple of minutes. Answer **Yes** to any trust prompt.

### 1.3 Run Script 1

Put all the files in a folder such as `C:\ZT`, then:

```powershell
cd C:\ZT
.\fa_Bootstrap-ZtApp.ps1 -AppDisplayName "Zero Trust Assessment - CustomerName"
```

A browser window opens. Sign in as the Global Administrator and approve the
permissions request.

The script then prints its progress — creating the app, adding around 35
read-only permissions, granting consent, assigning the Global Reader role. It
takes two to three minutes.

**When it finishes** it creates a file called `config.json` and prints three
IDs. You don't need to copy them anywhere — they're already in the file.

> **What did that just do?** It created an identity that can *read* the
> customer's tenant configuration — users, policies, devices, security settings
> — and nothing else. It cannot change anything.

---

## Part 2 — Fill in the settings file

Open `config.json` in Notepad (or any text editor). Find every value that says
`EDIT ME` and replace it. There are usually three:

- `baseTags` → `created by` — your email address
- `baseTags` → `sme` — the subject matter expert's email
- `vmExtraTags` → `Owner` — the service owner's email

Also check these, using the answers from your customer questions:

| Setting | What to check |
|---|---|
| `vmSize` | Must be a size their policy allows |
| `location` | The Azure region to deploy into |
| `resourceGroup` | The name to use; the default is fine |
| `scheduleStartTime` | When the first monthly run happens (already set a week ahead) |
| Other tag values | Must match what their policy requires |

Save the file.

> Keep the quotation marks and commas exactly as they are — only change the
> text between the quotes. If the file gets mangled, Script 2 will tell you.

---

## Part 3 — Build everything in Azure (Script 2)

*Done in **Azure Cloud Shell**, which runs inside the browser. Nothing to
install, and it avoids sign-in problems.*

### 3.1 Open Cloud Shell

1. Go to **portal.azure.com** and sign in.
2. Click the **`>_`** icon in the top toolbar.
3. Choose **PowerShell** if asked, and accept the storage prompt.

### 3.2 Upload the files

In the Cloud Shell toolbar click **Manage files → Upload**, and upload these
six files (you can select them all at once):

- `config.json` (the one you just edited)
- `fa_Deploy-ZtAssessment.ps1`
- `fa_Complete-ZtSetup.ps1`
- `fa_main.bicep`
- `fa_vm-setup.ps1`
- `fa_ztassessment-runbook-cert.ps1`
- `fa_ztassessment-orchestrator.ps1`

### 3.3 Check you're pointed at the right subscription

```powershell
az account show --query name -o tsv
```

If it's the wrong one:

```powershell
az account list -o table
az account set --subscription "<the right one>"
```

### 3.4 Run Script 2

> **Important — don't walk away.** Cloud Shell disconnects after about 20
> minutes of inactivity, and this script takes 15–25 minutes. If the session
> drops mid-run you'll see errors like *"The working directory has been deleted
> or recreated"* and *"Please run 'az login'"*, and the script stops partway.
> Stay at the keyboard, or click in the Cloud Shell window every few minutes to
> keep it alive.

```powershell
./fa_Deploy-ZtAssessment.ps1 -ConfigFile config.json
```

It asks for a password for the virtual machine's administrator account. Invent
a strong one (at least 12 characters, mixed case, numbers, symbols) and keep it
somewhere safe — you'll rarely need it, but it can't be recovered.

The script then works through everything: creating the resource group, staging
storage, downloading and uploading the PowerShell installer, generating access
links, and deploying about 25 Azure resources.

**This takes 15–25 minutes.** Leave the browser tab open. Success looks like:

```
  Deployment succeeded.
============================================================
 DEPLOYMENT COMPLETE
```

> **If it fails**, the script prints a plain-English explanation of what went
> wrong and what to change. Fix the issue (usually a value in `config.json`)
> and just run the script again — it picks up where it left off and never
> duplicates anything.

---

## Part 4 — Finish and test (Script 3)

### 4.1 Check the session is still healthy

Before running the second script, confirm Cloud Shell hasn't dropped in the
meantime. This takes two seconds and saves a half-finished run:

```powershell
cd ~
az account show --query name -o tsv
ls fa_*
```

If that prints your subscription name and lists the files, carry on. If it
errors, close Cloud Shell and open it again, then `cd ~` and continue — your
files are still there.

> **Why this matters:** if the session has dropped, Script 3 fails partway
> through. Typically the certificate gets attached but the **Reader role
> assignment is skipped**, which leaves the Azure part of the assessment
> failing later for no obvious reason.

### 4.2 Run Script 3

```powershell
./fa_Complete-ZtSetup.ps1 -ConfigFile config.json
```

A browser window opens once more — sign in as an administrator who can update
app registrations.

The script then:

1. Takes the security certificate Azure just created and registers it against
   the identity from Part 1, so the assessment can sign in as itself.
2. Grants the assessment read access to the Azure subscription.
3. Checks the virtual machine finished installing its software.
4. Starts a full test run and watches it.

**The test run takes 45–90 minutes.** The job runs in Azure, so closing the
window doesn't stop it — but Cloud Shell will time out long before the run
finishes, so you'll lose the live output.

> **Recommended:** run it as `./fa_Complete-ZtSetup.ps1 -ConfigFile config.json
> -SkipTestRun` instead. That does the certificate and permissions work — the
> parts that need to succeed — without tying up the session for an hour. Then
> start the assessment from the portal (**Automation account → Runbooks →
> ZeroTrustAssessment-Orchestrator → Start**) and watch it on the job page,
> which streams live and never times out.

Success ends with:

```
============================================================
 SUCCESS - the assessment ran end to end
============================================================
```

---

## Part 5 — Look at the report

1. In the portal, go to **Storage accounts** and open the one beginning
   `ztassess…` (not the `ztstg…` one — that's just staging).
2. Click **Containers → ztassessment**.
3. Download the file ending `.html` and open it in a browser.

You'll see a scored assessment across Identity, Devices, Data, Network and
other areas, with recommendations for each finding.

> A few tests will show errors mentioning "401" or "AccessDenied". This is
> normal and expected: a small number of Microsoft endpoints can only be read
> by a signed-in human administrator, never by an automated process.

---

## That's it — what happens from now on

- **Every month**, on the schedule you set, the VM starts itself, runs the
  assessment, uploads the report, and shuts down again. Nobody needs to do
  anything.
- **The VM is switched off** between runs, so it costs only a few pounds a
  month for its disk.
- **Reports older than 90 days delete themselves** automatically.

### Things to diarise

| When | What |
|---|---|
| In 2 years | The certificate expires — ask for it to be renewed before then |
| Every few months | Re-run `fa_Add-ZtAppPermissions.ps1` — new versions of the assessment occasionally need new permissions |
| Before re-deploying | The staging access links expire after 30 days; just re-run Script 2, which regenerates them |

---

## If something goes wrong

**"Module not installed"** — go back to step 1.2.

**"EDIT ME"** — Script 2 found unfilled values in `config.json`. Fill them in.

**"disallowed by policy" mentioning virtual machine size** — the `vmSize` in
`config.json` isn't allowed. Ask which sizes are, and change it.

**"disallowed by policy" mentioning tags** — a tag value isn't acceptable to
their policy. Check the tag values in `config.json`.

**"exceeded your quota"** — the subscription has hit a limit in that region.
Change `location` in `config.json` to a different region and re-run.

**"AuthorizationFailed" or "does not have authorization"** — your Azure account
isn't Owner. Ask for Owner on the resource group, or have someone who has it
run Scripts 2 and 3.

**"multi-factor" or "MFA"** — you're running the Azure CLI on your own machine.
Use Cloud Shell instead, which never has this problem.

**The test run fails** — most often the certificate hasn't finished replicating
across Microsoft's systems. Wait ten minutes and run Script 3 again; it skips
everything already done and just re-tests.

**"The working directory has been deleted or recreated" / "Please run 'az
login'"** — Cloud Shell timed out mid-script. Close it, open it again, `cd ~`,
and re-run the script. Check afterwards that the Reader role was actually
assigned (see below).

**The Azure part of the report is empty, or the assessment can't reach Azure** —
the Reader role assignment probably didn't happen, usually because of a dropped
session. Check and fix with:

```powershell
az role assignment list --assignee <servicePrincipalObjectId from config.json> --query "[].roleDefinitionName" -o tsv
az role assignment create --assignee <servicePrincipalObjectId> --role Reader --scope /subscriptions/$(az account show --query id -o tsv)
```

**The Infrastructure section of the report is blank** — this is expected unless
the subscriptions have been tagged. The Infrastructure pillar only looks at
subscriptions carrying the tag name `ZeroTrustAssessment` with the value
`Infrastructure`. Add it under Subscription → Tags, make sure the service
principal has Reader there, and it will populate on the next run.

**A few tests show 401 or AccessDenied** — expected. A small number of Microsoft
endpoints can only be read by a signed-in human administrator, never by an
automated process. Nothing to fix.

**Anything else** — re-running any of the three scripts is always safe. They
detect what already exists and only do what's missing.
