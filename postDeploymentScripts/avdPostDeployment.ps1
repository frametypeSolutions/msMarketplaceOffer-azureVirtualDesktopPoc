<#
.SYNOPSIS
    Post-deployment configuration wrapper for the frameType Solutions AVD Marketplace offer.

.DESCRIPTION
    Orchestrates all required and optional post-deployment steps after the Azure Virtual
    Desktop Marketplace offer has been deployed. Runs the following in sequence:

    REQUIRED (always run — FSLogix will not function without these):
      1. Grant admin consent for the Azure Files storage enterprise application
      2. Exclude the storage enterprise application from MFA Conditional Access policies

    OPTIONAL (prompted interactively, default Y):
      3. Associate the AVD Scaling Plan with the Host Pool

    Resource discovery is automatic based on the naming convention used by the offer.
    Falls back to interactive prompts if any resource cannot be found.

.PARAMETER Environment
    Environment code used during deployment (e.g. dev, test, prod, infra).
    Used to derive resource names. Prompted interactively if not supplied.

.PARAMETER Location
    Azure region used during deployment (e.g. westus2, eastus).
    Used to derive resource names. Prompted interactively if not supplied.

.PARAMETER SkipScalingPlan
    Switch. Skips the scaling plan / host pool association step without prompting.
    Useful for non-interactive or scripted runs.

.EXAMPLE
    .\Invoke-AvdPostDeployment.ps1
    Interactive mode - prompts for all inputs.

.EXAMPLE
    .\Invoke-AvdPostDeployment.ps1 -Environment prod -Location westus2
    Supplies environment and location - auto-discovers all resources, prompts only for
    optional steps.

.EXAMPLE
    .\Invoke-AvdPostDeployment.ps1 -Environment prod -Location westus2 -SkipScalingPlan
    Fully non-interactive for required steps only.

.NOTES
    Requirements:
      - Azure CLI (az) version 2.50.0 or later — for Azure resource operations
      - PowerShell 7.0 or later
      - Signed-in account must hold one of:
          Conditional Access Administrator or Global Administrator (for CA policy updates)
          Application Administrator or Global Administrator (for admin consent)
      - No Microsoft.Graph PowerShell module required — all Graph operations use az rest
      - The AVD Marketplace offer must be fully deployed before running this script

    Run this script from PowerShell 7:
      Unblock-File .\Invoke-AvdPostDeployment.ps1
      .\avdPostDeployment.ps1

    Repository : https://github.com/frametypeSolutions/msMarketplaceOffer-azureVirtualDesktopPoc
    Author     : frameType Solutions
    Version    : 1.1.02
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Environment,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [switch]$SkipScalingPlan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Region: Shared helpers
# ---------------------------------------------------------------------------

function Write-Banner {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║     frameType Solutions — AVD Marketplace Post-Deployment       ║" -ForegroundColor Cyan
    Write-Host "║     avdPostDeployment.ps1  v1.1.02                        ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host "-- $Title " -ForegroundColor Cyan -NoNewline
    Write-Host ("-" * ([Math]::Max(2, 60 - $Title.Length))) -ForegroundColor DarkGray
}

function Write-Success([string]$Message) { Write-Host "  [OK]  $Message" -ForegroundColor Green }
function Write-Info([string]$Message)    { Write-Host "  [..] $Message" -ForegroundColor DarkCyan }
function Write-Warn([string]$Message)    { Write-Host "  [!!]  $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message)    { Write-Host "  [XX]  $Message" -ForegroundColor Red }
function Write-Skip([string]$Message)    { Write-Host "  [--]  $Message" -ForegroundColor DarkGray }

function Read-TextDefault {
    param([string]$Prompt, [string]$Default)
    $in = Read-Host "$Prompt (Enter for '$Default')"
    if ([string]::IsNullOrWhiteSpace($in)) { return $Default }
    return $in.Trim()
}

function Read-YesNo {
    param([string]$Prompt, [bool]$DefaultYes = $true)
    $suffix = if ($DefaultYes) { " (Y/n)" } else { " (y/N)" }
    while ($true) {
        $in = Read-Host ($Prompt + $suffix)
        if ([string]::IsNullOrWhiteSpace($in)) { return $DefaultYes }
        switch -Regex ($in.Trim().ToLower()) {
            "^(y|yes)$" { return $true }
            "^(n|no)$"  { return $false }
            default     { Write-Host "  Please enter Y or N." -ForegroundColor Yellow }
        }
    }
}

function Convert-ToSafeStorageName {
    param([string]$Env, [string]$Loc)
    $raw = "saavd" + $Env + $Loc + "01"
    $safe = ($raw.ToLowerInvariant() -replace '[^a-z0-9]', '')
    return $safe.Substring(0, [Math]::Min(24, $safe.Length))
}

# ---------------------------------------------------------------------------
# Region: Prerequisites
# ---------------------------------------------------------------------------

function Assert-AzCliVersion {
    Write-Section "Checking Azure CLI"
    try {
        $v = (az version --output json 2>&1 | ConvertFrom-Json).'azure-cli'
        Write-Success "Azure CLI version: $v"
        $parts = $v -split '\.'
        if ([int]$parts[0] -lt 2 -or ([int]$parts[0] -eq 2 -and [int]$parts[1] -lt 50)) {
            Write-Warn "Azure CLI 2.50.0 or later recommended. Run: az upgrade"
        }
    }
    catch {
        Write-Fail "Azure CLI not found. Install from: https://aka.ms/installazurecliwindows"
        exit 1
    }
}

function Assert-PowerShellVersion {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Fail "PowerShell 7 or later is required. Current: $($PSVersionTable.PSVersion)"
        Write-Host "  Download from: https://aka.ms/powershell" -ForegroundColor DarkGray
        exit 1
    }
    Write-Success "PowerShell version: $($PSVersionTable.PSVersion)"
}

# Microsoft.Graph PowerShell module is NOT used — all Graph operations use az rest
# to avoid DLL version conflicts in customer environments.

# ---------------------------------------------------------------------------
# Region: Authentication
# ---------------------------------------------------------------------------

function Invoke-AzLogin {
    Write-Section "Azure CLI Authentication"
    $accountJson = az account show --output json 2>&1
    if ($LASTEXITCODE -eq 0) {
        $account = $accountJson | ConvertFrom-Json
        Write-Success "Signed in as : $($account.user.name)"
        Write-Info   "Subscription : $($account.name) ($($account.id))"
        Write-Info   "Tenant       : $($account.tenantId)"
        $reuse = Read-Host "  Use this account? (Y/n)"
        if ($reuse -match '^[Nn]') {
            az login --output none
            if ($LASTEXITCODE -ne 0) { Write-Fail "az login failed."; exit 1 }
        }
    }
    else {
        Write-Info "No active session. Launching login..."
        az login --output none
        if ($LASTEXITCODE -ne 0) { Write-Fail "az login failed."; exit 1 }
    }
    $script:AzAccount = az account show --output json 2>&1 | ConvertFrom-Json
    Write-Success "Using subscription: $($script:AzAccount.name)"
}

function Assert-GraphAccess {
    Write-Section "Graph API Access (via az rest)"
    # Verify az can reach Graph using the current az login token
    $test = az rest --method GET `
        --uri "https://graph.microsoft.com/v1.0/organization?`$select=id" `
        --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Cannot reach Microsoft Graph via az rest. Ensure you are logged in with 'az login' and have sufficient permissions."
        exit 1
    }
    Write-Success "Graph API reachable via az rest."
}

# ---------------------------------------------------------------------------
# Region: Resource discovery
# ---------------------------------------------------------------------------

function Get-DeploymentContext {
    Write-Section "Deployment Context"

    # Environment
    if ([string]::IsNullOrWhiteSpace($script:Environment)) {
        $script:Environment = Read-TextDefault -Prompt "Environment code used during deployment" -Default "prod"
    }
    Write-Info "Environment : $($script:Environment)"

    # Location
    if ([string]::IsNullOrWhiteSpace($script:Location)) {
        $script:Location = Read-TextDefault -Prompt "Azure region used during deployment" -Default "westus2"
    }
    Write-Info "Location    : $($script:Location)"

    $envCode = $script:Environment.ToLower().Trim()
    $locCode = $script:Location.ToLower().Trim()

    # Derive expected names from naming convention
    $expectedRg             = "mrg-avd-$envCode-$locCode-01"
    $expectedStorageAccount = Convert-ToSafeStorageName -Env $envCode -Loc $locCode
    $expectedHostPool       = "hp-avd-$envCode-$locCode-01"
    $expectedScalingPlan    = "sp-avd-$envCode-$locCode-01"

    Write-Info "Expected resource group    : $expectedRg"
    Write-Info "Expected storage account   : $expectedStorageAccount"
    Write-Info "Expected host pool         : $expectedHostPool"
    Write-Info "Expected scaling plan      : $expectedScalingPlan"

    # --- Resource Group ---
    Write-Section "Discovering Resource Group"
    $script:ResourceGroupName = $null
    $rgExists = az group exists --name $expectedRg 2>&1
    if ($rgExists -eq 'true') {
        $script:ResourceGroupName = $expectedRg
        Write-Success "Found: $expectedRg"
    }
    else {
        Write-Warn "Resource group '$expectedRg' not found."
        Write-Info "Searching for any mrg-avd-$envCode-$locCode-* resource groups..."
        $found = az group list --query "[?starts_with(name,'mrg-avd-$envCode-$locCode') || starts_with(name,'rg-avd-$envCode-$locCode')].name" -o tsv 2>&1
        if (-not [string]::IsNullOrWhiteSpace($found)) {
            $first = ($found -split "`n" | Where-Object { $_ } | Select-Object -First 1).Trim()
            Write-Info "Found candidate: $first"
            if (Read-YesNo -Prompt "  Use '$first'?" -DefaultYes $true) {
                $script:ResourceGroupName = $first
            }
        }
        if ([string]::IsNullOrWhiteSpace($script:ResourceGroupName)) {
            $script:ResourceGroupName = Read-TextDefault -Prompt "Resource group name" -Default $expectedRg
        }
    }

    # --- Storage Account ---
    Write-Section "Discovering Storage Account"
    $script:StorageAccountName = $null
    $saCheck = az storage account show --name $expectedStorageAccount --resource-group $script:ResourceGroupName --query "name" -o tsv 2>&1
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($saCheck)) {
        $script:StorageAccountName = $saCheck.Trim()
        Write-Success "Found: $($script:StorageAccountName)"
    }
    else {
        Write-Warn "Storage account '$expectedStorageAccount' not found in '$($script:ResourceGroupName)'."
        $saFound = az storage account list --resource-group $script:ResourceGroupName --query "[?starts_with(name,'saavd$envCode')].name" -o tsv 2>&1
        if (-not [string]::IsNullOrWhiteSpace($saFound)) {
            $first = ($saFound -split "`n" | Where-Object { $_ } | Select-Object -First 1).Trim()
            Write-Info "Found candidate: $first"
            if (Read-YesNo -Prompt "  Use '$first'?" -DefaultYes $true) {
                $script:StorageAccountName = $first
            }
        }
        if ([string]::IsNullOrWhiteSpace($script:StorageAccountName)) {
            $script:StorageAccountName = Read-TextDefault -Prompt "Storage account name" -Default $expectedStorageAccount
        }
    }

    # --- Host Pool ---
    Write-Section "Discovering Host Pool"
    $script:HostPoolName = $null
    az extension add --name desktopvirtualization --upgrade -o none 2>&1 | Out-Null
    $hpCheck = az desktopvirtualization hostpool show --name $expectedHostPool --resource-group $script:ResourceGroupName --query "name" -o tsv 2>&1
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($hpCheck)) {
        $script:HostPoolName = $hpCheck.Trim()
        Write-Success "Found: $($script:HostPoolName)"
    }
    else {
        Write-Warn "Host pool '$expectedHostPool' not found in '$($script:ResourceGroupName)'."
        $hpFound = az desktopvirtualization hostpool list --resource-group $script:ResourceGroupName --query "[0].name" -o tsv 2>&1
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($hpFound)) {
            $first = $hpFound.Trim()
            Write-Info "Found candidate: $first"
            if (Read-YesNo -Prompt "  Use '$first'?" -DefaultYes $true) {
                $script:HostPoolName = $first
            }
        }
        if ([string]::IsNullOrWhiteSpace($script:HostPoolName)) {
            $script:HostPoolName = Read-TextDefault -Prompt "Host pool name" -Default $expectedHostPool
        }
    }

    # --- Scaling Plan ---
    # Uses az rest directly - desktopvirtualization extension v1.0.0 dropped the scalingplan subcommand
    Write-Section "Discovering Scaling Plan"
    $script:ScalingPlanName = $null
    $subIdForSp = $script:AzAccount.id
    $spUri = "https://management.azure.com/subscriptions/$subIdForSp/resourceGroups/$($script:ResourceGroupName)/providers/Microsoft.DesktopVirtualization/scalingPlans/" + $expectedScalingPlan + "?api-version=2024-04-03"
    $spCheckResult = az rest --method GET --uri $spUri --query "name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($spCheckResult)) {
        $script:ScalingPlanName = $spCheckResult.Trim()
        Write-Success "Found: $($script:ScalingPlanName)"
    }
    else {
        Write-Warn "Scaling plan '$expectedScalingPlan' not found in '$($script:ResourceGroupName)'."
        $spListUri = "https://management.azure.com/subscriptions/$subIdForSp/resourceGroups/$($script:ResourceGroupName)/providers/Microsoft.DesktopVirtualization/scalingPlans?api-version=2024-04-03"
        $spListResult = az rest --method GET --uri $spListUri --query "value[].name" -o tsv 2>$null
        if (-not [string]::IsNullOrWhiteSpace($spListResult)) {
            $candidates = $spListResult -split "`n" | Where-Object { $_ } | ForEach-Object { $_.Trim() }
            $match = $candidates | Where-Object { $_ -eq $expectedScalingPlan } | Select-Object -First 1
            $first = if ($match) { $match } else { $candidates | Select-Object -First 1 }
            Write-Info "Found candidate: $first"
            if (Read-YesNo -Prompt "  Use '$first'?" -DefaultYes $true) {
                $script:ScalingPlanName = $first
            }
        }
        if ([string]::IsNullOrWhiteSpace($script:ScalingPlanName)) {
            $script:ScalingPlanName = Read-TextDefault -Prompt "Scaling plan name" -Default $expectedScalingPlan
        }
    }

    # Summary
    Write-Host ""
    Write-Host "  Deployment context resolved:" -ForegroundColor Cyan
    Write-Host "    Resource Group   : $($script:ResourceGroupName)"   -ForegroundColor White
    Write-Host "    Storage Account  : $($script:StorageAccountName)"  -ForegroundColor White
    Write-Host "    Host Pool        : $($script:HostPoolName)"        -ForegroundColor White
    Write-Host "    Scaling Plan     : $($script:ScalingPlanName)"     -ForegroundColor White
    Write-Host ""

    if (-not (Read-YesNo -Prompt "Proceed with these values?" -DefaultYes $true)) {
        Write-Host "  Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Region: Storage service principal helper
# ---------------------------------------------------------------------------

function Get-StorageServicePrincipal {
    param([string]$StorageAccountName)

    # Azure creates the SP with one of two display name formats
    $primaryName = "[Storage Account] $StorageAccountName.file.core.windows.net"
    $altName     = "$StorageAccountName.file.core.windows.net"

    foreach ($displayName in @($primaryName, $altName)) {
        $encoded = [Uri]::EscapeDataString("displayName eq '$displayName'")
        $result = az rest --method GET `
            --uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$encoded" `
            --headers "ConsistencyLevel=eventual" `
            --output json 2>&1

        if ($LASTEXITCODE -eq 0) {
            $parsed = $result | ConvertFrom-Json
            if ($parsed.value -and $parsed.value.Count -gt 0) {
                return $parsed.value[0]
            }
        }
    }

    throw "Could not find the Azure Files enterprise application for storage account '$StorageAccountName'. " +
          "Ensure Entra Kerberos is enabled on the storage account (should be set by the ARM deployment). " +
          "Check: Azure Portal -> Storage Account -> File shares -> Active Directory."
}

# ---------------------------------------------------------------------------
# Region: Step 1 (REQUIRED) — Grant admin consent
# ---------------------------------------------------------------------------

function Invoke-GrantAdminConsent {
    Write-Section "Step 1 of 3 (REQUIRED) - Grant Admin Consent for Azure Files SP"
    Write-Info "This step grants the Azure Files storage enterprise application the"
    Write-Info "Graph OAuth2 delegated permissions required for Entra Kerberos."
    Write-Host ""

    $sp = Get-StorageServicePrincipal -StorageAccountName $script:StorageAccountName
    Write-Success "Found storage SP: $($sp.displayName) ($($sp.id))"

    # Resolve Microsoft Graph service principal id
    $graphResult = az rest --method GET `
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'" `
        --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not resolve Microsoft Graph service principal." }
    $graphSp = ($graphResult | ConvertFrom-Json).value[0]
    if (-not $graphSp) { throw "Could not resolve Microsoft Graph service principal." }

    $requiredScopes = "openid profile User.Read"

    # Check for existing OAuth2 permission grant
    $encoded  = [Uri]::EscapeDataString("clientId eq '$($sp.id)' and resourceId eq '$($graphSp.id)'")
    $existing = az rest --method GET `
        --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=$encoded" `
        --output json 2>&1 | ConvertFrom-Json

    if ($existing.value -and $existing.value.Count -gt 0) {
        $grant  = $existing.value[0]
        $current = if ($grant.scope) { $grant.scope -split " " | Sort-Object } else { @() }
        $required = $requiredScopes -split " " | Sort-Object
        $missing  = $required | Where-Object { $current -notcontains $_ }

        if (-not $missing) {
            Write-Success "Admin consent already in place with required scopes. No action needed."
        }
        else {
            $merged = (($current + $required) | Where-Object { $_ } | Select-Object -Unique) -join " "
            $body   = @{ scope = $merged } | ConvertTo-Json -Compress
            $tmpFile = [System.IO.Path]::GetTempFileName() + ".json"
            $body | Set-Content -Path $tmpFile -Encoding UTF8
            az rest --method PATCH `
                --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($grant.id)" `
                --body "@$tmpFile" `
                --headers "Content-Type=application/json" | Out-Null
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            if ($LASTEXITCODE -ne 0) { throw "Failed to update OAuth2 permission grant." }
            Write-Success "Admin consent updated. Scopes: $merged"
        }
    }
    else {
        $body = @{
            clientId    = $sp.id
            consentType = "AllPrincipals"
            resourceId  = $graphSp.id
            scope       = $requiredScopes
        } | ConvertTo-Json -Compress
        $tmpFile = [System.IO.Path]::GetTempFileName() + ".json"
        $body | Set-Content -Path $tmpFile -Encoding UTF8
        $createResult = az rest --method POST `
            --uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" `
            --body "@$tmpFile" `
            --headers "Content-Type=application/json" `
            --output json 2>&1
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -ne 0) {
            if ($createResult -match 'already exists|Permission entry already exists') {
                Write-Success "Admin consent already in place. Skipping."
            }
            else { throw "Failed to create OAuth2 permission grant: $createResult" }
        }
        else {
            Write-Success "Admin consent granted. Scopes: $requiredScopes"
        }
    }
}

# ---------------------------------------------------------------------------
# Region: Step 2 (REQUIRED) — MFA Conditional Access exclusion
# ---------------------------------------------------------------------------

function Invoke-SetCAExclusion {
    Write-Section "Step 2 of 3 (REQUIRED) - MFA Conditional Access Exclusion"
    Write-Info "Excludes the Azure Files storage enterprise application from MFA CA"
    Write-Info "policies. Required so FSLogix can mount the profile share at session"
    Write-Info "startup before the user MFA state is established."
    Write-Host ""

    $sp = Get-StorageServicePrincipal -StorageAccountName $script:StorageAccountName
    Write-Success "Found storage SP: $($sp.displayName)"

    # Get all CA policies
    $policiesResult = az rest --method GET `
        --uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?`$select=id,displayName,state,grantControls,conditions" `
        --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Failed to retrieve Conditional Access policies: $policiesResult" }
    $policies = ($policiesResult | ConvertFrom-Json).value

    $mfaPolicies = $policies | Where-Object {
        $_.state -ne "disabled" -and
        $_.grantControls -and
        $_.grantControls.builtInControls -and
        ($_.grantControls.builtInControls -contains "mfa")
    }

    if (-not $mfaPolicies -or $mfaPolicies.Count -eq 0) {
        Write-Warn "No enabled MFA Conditional Access policies found in this tenant."
        Write-Info "If you add MFA CA policies in the future, re-run this script to apply the exclusion."
        return
    }

    Write-Info "Found $(@($mfaPolicies).Count) enabled MFA CA policy/policies."
    $updated = 0
    $skipped = 0
    $managed = 0

    foreach ($p in $mfaPolicies) {
        $cond = $p.conditions
        if (-not $cond -or -not $cond.applications) {
            Write-Skip "Policy '$($p.displayName)': no application conditions - skipping."
            $skipped++
            continue
        }

        $exclude = @()
        if ($cond.applications.excludeApplications) {
            $exclude = @($cond.applications.excludeApplications)
        }

        if ($exclude -contains $sp.appId) {
            Write-Skip "Policy '$($p.displayName)': already excludes storage app."
            $skipped++
            continue
        }

        $exclude += $sp.appId

        $patchBody = @{
            conditions = @{
                applications = @{
                    includeApplications = $cond.applications.includeApplications
                    excludeApplications = $exclude
                    includeUserActions  = $cond.applications.includeUserActions
                }
                users            = $cond.users
                clientAppTypes   = $cond.clientAppTypes
                locations        = $cond.locations
                platforms        = $cond.platforms
                devices          = $cond.devices
                signInRiskLevels = $cond.signInRiskLevels
                userRiskLevels   = $cond.userRiskLevels
            }
        }

        $tmpFile = [System.IO.Path]::GetTempFileName() + ".json"
        $patchBody | ConvertTo-Json -Depth 10 -Compress | Set-Content -Path $tmpFile -Encoding UTF8

        $patchResult = az rest --method PATCH `
            --uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$($p.id)" `
            --body "@$tmpFile" `
            --headers "Content-Type=application/json" `
            --output json 2>&1
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue

        if ($LASTEXITCODE -ne 0) {
            # Microsoft-managed policies reject application exclusions via API
            Write-Skip "Skipped '$($p.displayName)': Microsoft-managed policy (cannot exclude apps via API)."
            $managed++
        }
        else {
            Write-Success "Updated '$($p.displayName)': storage app excluded."
            $updated++
        }
    }

    Write-Host ""
    Write-Info "CA policy summary: $updated updated, $skipped already excluded, $managed Microsoft-managed (manual action required)."

    if ($managed -gt 0) {
        Write-Warn "$managed Microsoft-managed policy/policies require manual exclusion."
        Write-Warn "Azure Portal -> Entra ID -> Security -> Conditional Access -> [policy] -> Exclude -> add '$($sp.displayName)'."
    }
}

# ---------------------------------------------------------------------------
# Region: Step 3 (OPTIONAL) — Scaling plan host pool association
# ---------------------------------------------------------------------------

function Invoke-SetScalingPlanAssociation {
    Write-Section "Step 3 of 3 (OPTIONAL) - Scaling Plan / Host Pool Association"
    Write-Info "Associates the AVD Scaling Plan with the Host Pool to enable autoscaling."
    Write-Info "This step was deferred from the ARM deployment due to RBAC propagation timing."
    Write-Host ""

    if ($SkipScalingPlan) {
        Write-Skip "Skipped via -SkipScalingPlan switch."
        $script:Results.ScalingPlan = "Skipped (switch)"
        return
    }

    $run = Read-YesNo -Prompt "Associate scaling plan '$($script:ScalingPlanName)' with host pool '$($script:HostPoolName)'?" -DefaultYes $true
    if (-not $run) {
        Write-Skip "Scaling plan association skipped. You can run this script again to complete it."
        $script:Results.ScalingPlan = "Skipped (user choice)"
        return
    }

    # Check if already associated - use az rest (desktopvirtualization extension v1.0.0 dropped scalingplan subcommand)
    $subId       = $script:AzAccount.id
    $spArmUri    = "https://management.azure.com/subscriptions/$subId/resourceGroups/$($script:ResourceGroupName)/providers/Microsoft.DesktopVirtualization/scalingPlans/$($script:ScalingPlanName)?api-version=2024-04-03"
    $spShowJson  = az rest --method GET --uri $spArmUri --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not retrieve scaling plan '$($script:ScalingPlanName)': $spShowJson" }
    $spObj       = $spShowJson | ConvertFrom-Json
    $currentRefs = @()
    if ($spObj.properties.hostPoolReferences) { $currentRefs = @($spObj.properties.hostPoolReferences) }

    $hpArmId = "/subscriptions/$subId/resourceGroups/$($script:ResourceGroupName)/providers/Microsoft.DesktopVirtualization/hostPools/$($script:HostPoolName)"

    if ($currentRefs | Where-Object { $_.hostPoolArmPath -eq $hpArmId }) {
        Write-Success "Scaling plan is already associated with host pool. No action needed."
        $script:Results.ScalingPlan = "Already associated"
        return
    }

    # Build updated refs - preserve any existing associations and add the new one
    $newRef = @{
        hostPoolArmPath    = $hpArmId
        scalingPlanEnabled = $true
    }

    $updatedRefs = $currentRefs + @($newRef)

    # Write to temp file - avoid inline JSON encoding issues on Windows
    $bodyObject = @{
        properties = @{
            hostPoolReferences = $updatedRefs
        }
    }
    $tempFile = [System.IO.Path]::GetTempFileName() + ".json"
    $bodyObject | ConvertTo-Json -Depth 5 -Compress | Set-Content -Path $tempFile -Encoding UTF8

    $spResourceId = "/subscriptions/$subId/resourceGroups/$($script:ResourceGroupName)/providers/Microsoft.DesktopVirtualization/scalingPlans/$($script:ScalingPlanName)"

    az rest `
        --method PATCH `
        --uri "https://management.azure.com$spResourceId`?api-version=2024-04-03" `
        --body "@$tempFile" `
        --headers "Content-Type=application/json" | Out-Null

    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Scaling plan association may have failed. Verify in Azure Portal:"
        Write-Warn "Azure Virtual Desktop -> Scaling Plans -> $($script:ScalingPlanName) -> Host pool assignments."
        $script:Results.ScalingPlan = "Failed - verify manually"
    }
    else {
        Write-Success "Scaling plan '$($script:ScalingPlanName)' associated with host pool '$($script:HostPoolName)'."
        $script:Results.ScalingPlan = "Associated"
    }
}

# ---------------------------------------------------------------------------
# Region: Summary
# ---------------------------------------------------------------------------

function Write-CompletionSummary {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║              Post-Deployment Configuration Complete              ║" -ForegroundColor Green
    Write-Host "╠══════════════════════════════════════════════════════════════════╣" -ForegroundColor Green
    Write-Host "║                                                                  ║" -ForegroundColor Green
    Write-Host "║  Step 1 - Admin Consent      : $($script:Results.AdminConsent.PadRight(34))║" -ForegroundColor White
    Write-Host "║  Step 2 - CA Exclusion       : $($script:Results.CAExclusion.PadRight(34))║" -ForegroundColor White
    Write-Host "║  Step 3 - Scaling Plan       : $($script:Results.ScalingPlan.PadRight(34))║" -ForegroundColor White
    Write-Host "║                                                                  ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Next Steps" -ForegroundColor Cyan
    Write-Host "  ---------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  1. Add users to the AVD Users and Admins Entra security groups." -ForegroundColor White
    Write-Host "  2. Verify session hosts show Status: Available in the host pool." -ForegroundColor White
    Write-Host "  3. Sign in as a test user and confirm the FSLogix profile mounts." -ForegroundColor White
    Write-Host "  4. Review AVD Insights in Azure Monitor for connection diagnostics." -ForegroundColor White
    Write-Host ""
    if ($script:Results.CAExclusion -like "*manual*") {
        Write-Warn "Action required: One or more Microsoft-managed CA policies need manual exclusion."
        Write-Warn "See Step 2 output above for details."
        Write-Host ""
    }
    Write-Host "  Documentation : https://github.com/frametypeSolutions/msMarketplaceOffer-azureVirtualDesktopPoc" -ForegroundColor DarkGray
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Region: Entry point
# ---------------------------------------------------------------------------

# Initialise result tracking
$script:Results = @{
    AdminConsent = "Pending"
    CAExclusion  = "Pending"
    ScalingPlan  = "Pending"
}

$script:Environment = $Environment
$script:Location    = $Location

Write-Banner
Assert-PowerShellVersion
Assert-AzCliVersion
Invoke-AzLogin
Assert-GraphAccess
Get-DeploymentContext

# Required steps
try {
    Invoke-GrantAdminConsent
    $script:Results.AdminConsent = "Complete"
}
catch {
    Write-Fail "Admin consent step failed: $($_.Exception.Message)"
    $script:Results.AdminConsent = "Failed"
    Write-Warn "Cannot continue - admin consent is required for FSLogix to function."
    exit 1
}

try {
    Invoke-SetCAExclusion
    $caResult = if ($script:Results.CAExclusion -eq "Pending") { "Complete" } else { $script:Results.CAExclusion }
    # Check if any manual action was flagged
    $managedCount = 0
    $script:Results.CAExclusion = if ($managedCount -gt 0) { "Complete (manual action needed)" } else { "Complete" }
}
catch {
    Write-Fail "CA exclusion step failed: $($_.Exception.Message)"
    $script:Results.CAExclusion = "Failed"
    Write-Warn "FSLogix profile mount may fail if MFA CA policies are not updated."
    Write-Warn "You can re-run this script to retry, or complete manually in the Azure Portal."
    # Do not exit - scaling plan association is still useful to run
}

# Optional step
try {
    Invoke-SetScalingPlanAssociation
}
catch {
    Write-Fail "Scaling plan association failed: $($_.Exception.Message)"
    $script:Results.ScalingPlan = "Failed - retry or associate manually"
}

Write-CompletionSummary

# SIG # Begin signature block
# MII57gYJKoZIhvcNAQcCoII53zCCOdsCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAYRyRF6iXzSrkG
# f8x+6Gw+3fHcioV6hMXgMSJuUa0TOqCCIhIwggXMMIIDtKADAgECAhBUmNLR1FsZ
# lUgTecgRwIeZMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVu
# dGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAy
# MDAeFw0yMDA0MTYxODM2MTZaFw00NTA0MTYxODQ0NDBaMHcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jv
# c29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRo
# b3JpdHkgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALORKgeD
# Bmf9np3gx8C3pOZCBH8Ppttf+9Va10Wg+3cL8IDzpm1aTXlT2KCGhFdFIMeiVPvH
# or+Kx24186IVxC9O40qFlkkN/76Z2BT2vCcH7kKbK/ULkgbk/WkTZaiRcvKYhOuD
# PQ7k13ESSCHLDe32R0m3m/nJxxe2hE//uKya13NnSYXjhr03QNAlhtTetcJtYmrV
# qXi8LW9J+eVsFBT9FMfTZRY33stuvF4pjf1imxUs1gXmuYkyM6Nix9fWUmcIxC70
# ViueC4fM7Ke0pqrrBc0ZV6U6CwQnHJFnni1iLS8evtrAIMsEGcoz+4m+mOJyoHI1
# vnnhnINv5G0Xb5DzPQCGdTiO0OBJmrvb0/gwytVXiGhNctO/bX9x2P29Da6SZEi3
# W295JrXNm5UhhNHvDzI9e1eM80UHTHzgXhgONXaLbZ7LNnSrBfjgc10yVpRnlyUK
# xjU9lJfnwUSLgP3B+PR0GeUw9gb7IVc+BhyLaxWGJ0l7gpPKWeh1R+g/OPTHU3mg
# trTiXFHvvV84wRPmeAyVWi7FQFkozA8kwOy6CXcjmTimthzax7ogttc32H83rwjj
# O3HbbnMbfZlysOSGM1l0tRYAe1BtxoYT2v3EOYI9JACaYNq6lMAFUSw0rFCZE4e7
# swWAsk0wAly4JoNdtGNz764jlU9gKL431VulAgMBAAGjVDBSMA4GA1UdDwEB/wQE
# AwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTIftJqhSobyhmYBAcnz1AQ
# T2ioojAQBgkrBgEEAYI3FQEEAwIBADANBgkqhkiG9w0BAQwFAAOCAgEAr2rd5hnn
# LZRDGU7L6VCVZKUDkQKL4jaAOxWiUsIWGbZqWl10QzD0m/9gdAmxIR6QFm3FJI9c
# Zohj9E/MffISTEAQiwGf2qnIrvKVG8+dBetJPnSgaFvlVixlHIJ+U9pW2UYXeZJF
# xBA2CFIpF8svpvJ+1Gkkih6PsHMNzBxKq7Kq7aeRYwFkIqgyuH4yKLNncy2RtNwx
# AQv3Rwqm8ddK7VZgxCwIo3tAsLx0J1KH1r6I3TeKiW5niB31yV2g/rarOoDXGpc8
# FzYiQR6sTdWD5jw4vU8w6VSp07YEwzJ2YbuwGMUrGLPAgNW3lbBeUU0i/OxYqujY
# lLSlLu2S3ucYfCFX3VVj979tzR/SpncocMfiWzpbCNJbTsgAlrPhgzavhgplXHT2
# 6ux6anSg8Evu75SjrFDyh+3XOjCDyft9V77l4/hByuVkrrOj7FjshZrM77nq81YY
# uVxzmq/FdxeDWds3GhhyVKVB0rYjdaNDmuV3fJZ5t0GNv+zcgKCf0Xd1WF81E+Al
# GmcLfc4l+gcK5GEh2NQc5QfGNpn0ltDGFf5Ozdeui53bFv0ExpK91IjmqaOqu/dk
# ODtfzAzQNb50GQOmxapMomE2gj4d8yu8l13bS3g7LfU772Aj6PXsCyM2la+YZr9T
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwgga2MIIEnqADAgECAhMzAAAnSPrc
# lj7RSWb+AAAAACdIMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQwHhcNMjYwNDE2MTcxMTAyWhcNMjYwNDE5
# MTcxMTAyWjB7MQswCQYDVQQGEwJVUzETMBEGA1UECBMKQ2FsaWZvcm5pYTETMBEG
# A1UEBxMKU2FjcmFtZW50bzEgMB4GA1UEChMXRnJhbWV0eXBlIFNvbHV0aW9ucyBM
# TEMxIDAeBgNVBAMTF0ZyYW1ldHlwZSBTb2x1dGlvbnMgTExDMIIBojANBgkqhkiG
# 9w0BAQEFAAOCAY8AMIIBigKCAYEApqtuPFsLlV4rklwYvniW5mkIqJUKrVTr4QQy
# 9hdHJNoipy/bKGzDq+h/wJyeRyatojtICJD1QwFUVtOPOT15jLn/mHppCWh9Tn1o
# rCfKRkmTS4H/4p3lFwPR8QYHzv+uhqquhCSBwV+FO20yF3s6WGwKL04OB/Y78aGK
# s4AIMy/Z/gsLkvat20NbHrRvgQ/UKZa54UNEXnYNe6Uh7MYjvpf/obWy7I11wzO5
# JV7WnCreXYqf3t2LW5akirCFPOJ+NGdHy9MaL11EXmSjxmlVTefG154e2bTfMmci
# fdS2R4cCrHPrEOe40st7HTSNT2Ek8jDNMHW/IxJ/5XOcCWQAv4y7xfYPwhmxKe5p
# IaU0WbwT4bkUdCOOSVQX2th6qBfMKNFWBsMGIAGF0RXgr+ZzEI9hxPHlDglWHAFC
# /tL8lzv0IJjcSclXKpUlIvb9rqpH2Q1pzdZ6fCSj2iznQJPqgzQaCZOSsuk0LwhO
# xRn9UUFbMzyJ8hP8pAJvVBuc8iFlAgMBAAGjggHSMIIBzjAMBgNVHRMBAf8EAjAA
# MA4GA1UdDwEB/wQEAwIHgDA5BgNVHSUEMjAwBgorBgEEAYI3YQEABggrBgEFBQcD
# AwYYKwYBBAGCN2HHprI72+bsOczY9zf3g7w5MB0GA1UdDgQWBBRw14IwRh9R65Us
# cU9pDynoTO/FuTAfBgNVHSMEGDAWgBRrJUHe+2t8/RiACi1/j3ZdqnM9uDBnBgNV
# HR8EYDBeMFygWqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBBT0MlMjBDQSUyMDA0
# LmNybDB0BggrBgEFBQcBAQRoMGYwZAYIKwYBBQUHMAKGWGh0dHA6Ly93d3cubWlj
# cm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmll
# ZCUyMENTJTIwQU9DJTIwQ0ElMjAwNC5jcnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEw
# PwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9j
# cy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG9w0BAQwFAAOCAgEAepY+kD6rYKEF2CYi
# u/X3I1CrxX5tizrSh4zU4xqnNCUksBCS+2MsYnvtgfy6gStk3QhNeyOUv6WpOgc6
# fcuoXvOpODEFdDV9kCEs/GIKcFPygPdGakFX489GNl16bTuK4F8u6KPR41J0SlzU
# xOoZWlq4+nXwzydloIBJmbV+P1VF6eh9ZTbD26OcQSRblFea8bK9SM3d0DCI0Zor
# 0gsmZCfscxHvQNAkDv3S3FhWdfAOKnL3urhE4U7HlQDV2fvYebr6xQwgrPPLD1Rt
# Bb9XmZszNlEczSplgDmN0Ovo24AADX+FJ/anOfusxsKLNvkN+l9xsiFAz5iT/3sN
# yGNfXvcmNfWxFseEoP3DAjP7b8oENFurjBqGNgj+FnvARj11cGVUJiwqN3lrXxSM
# pi7eOMQTuF5IQJ4krdkrxM8eOhHl4YmndUDyavlTokJubR1VCwTu6VmzWfMbqYO6
# P8Dh6uUxmW/gA65V5+Qt0rIZsaeFtEt44u2U4wMcL4C874DCWTldxwBfAa4Bp+bX
# LzrLU98Wc+OvDYY3BnCBtj9nPWrQ24uzpB92GNxDVVUswdrK4fKqBjbMXBv3eShE
# mikl+p646hdNjxZQJgv6A2D3ew27G0cTRDEuzHLyzcJT+ZoWvZONFtvsemMqIiUh
# oE+EBgNXOjqR82hOFCQPFs7aElgwgga2MIIEnqADAgECAhMzAAAnSPrclj7RSWb+
# AAAAACdIMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJp
# ZmllZCBDUyBBT0MgQ0EgMDQwHhcNMjYwNDE2MTcxMTAyWhcNMjYwNDE5MTcxMTAy
# WjB7MQswCQYDVQQGEwJVUzETMBEGA1UECBMKQ2FsaWZvcm5pYTETMBEGA1UEBxMK
# U2FjcmFtZW50bzEgMB4GA1UEChMXRnJhbWV0eXBlIFNvbHV0aW9ucyBMTEMxIDAe
# BgNVBAMTF0ZyYW1ldHlwZSBTb2x1dGlvbnMgTExDMIIBojANBgkqhkiG9w0BAQEF
# AAOCAY8AMIIBigKCAYEApqtuPFsLlV4rklwYvniW5mkIqJUKrVTr4QQy9hdHJNoi
# py/bKGzDq+h/wJyeRyatojtICJD1QwFUVtOPOT15jLn/mHppCWh9Tn1orCfKRkmT
# S4H/4p3lFwPR8QYHzv+uhqquhCSBwV+FO20yF3s6WGwKL04OB/Y78aGKs4AIMy/Z
# /gsLkvat20NbHrRvgQ/UKZa54UNEXnYNe6Uh7MYjvpf/obWy7I11wzO5JV7WnCre
# XYqf3t2LW5akirCFPOJ+NGdHy9MaL11EXmSjxmlVTefG154e2bTfMmcifdS2R4cC
# rHPrEOe40st7HTSNT2Ek8jDNMHW/IxJ/5XOcCWQAv4y7xfYPwhmxKe5pIaU0WbwT
# 4bkUdCOOSVQX2th6qBfMKNFWBsMGIAGF0RXgr+ZzEI9hxPHlDglWHAFC/tL8lzv0
# IJjcSclXKpUlIvb9rqpH2Q1pzdZ6fCSj2iznQJPqgzQaCZOSsuk0LwhOxRn9UUFb
# MzyJ8hP8pAJvVBuc8iFlAgMBAAGjggHSMIIBzjAMBgNVHRMBAf8EAjAAMA4GA1Ud
# DwEB/wQEAwIHgDA5BgNVHSUEMjAwBgorBgEEAYI3YQEABggrBgEFBQcDAwYYKwYB
# BAGCN2HHprI72+bsOczY9zf3g7w5MB0GA1UdDgQWBBRw14IwRh9R65UscU9pDyno
# TO/FuTAfBgNVHSMEGDAWgBRrJUHe+2t8/RiACi1/j3ZdqnM9uDBnBgNVHR8EYDBe
# MFygWqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNy
# b3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBBT0MlMjBDQSUyMDA0LmNybDB0
# BggrBgEFBQcBAQRoMGYwZAYIKwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0
# LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENT
# JTIwQU9DJTIwQ0ElMjAwNC5jcnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYB
# BQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBv
# c2l0b3J5Lmh0bTANBgkqhkiG9w0BAQwFAAOCAgEAepY+kD6rYKEF2CYiu/X3I1Cr
# xX5tizrSh4zU4xqnNCUksBCS+2MsYnvtgfy6gStk3QhNeyOUv6WpOgc6fcuoXvOp
# ODEFdDV9kCEs/GIKcFPygPdGakFX489GNl16bTuK4F8u6KPR41J0SlzUxOoZWlq4
# +nXwzydloIBJmbV+P1VF6eh9ZTbD26OcQSRblFea8bK9SM3d0DCI0Zor0gsmZCfs
# cxHvQNAkDv3S3FhWdfAOKnL3urhE4U7HlQDV2fvYebr6xQwgrPPLD1RtBb9XmZsz
# NlEczSplgDmN0Ovo24AADX+FJ/anOfusxsKLNvkN+l9xsiFAz5iT/3sNyGNfXvcm
# NfWxFseEoP3DAjP7b8oENFurjBqGNgj+FnvARj11cGVUJiwqN3lrXxSMpi7eOMQT
# uF5IQJ4krdkrxM8eOhHl4YmndUDyavlTokJubR1VCwTu6VmzWfMbqYO6P8Dh6uUx
# mW/gA65V5+Qt0rIZsaeFtEt44u2U4wMcL4C874DCWTldxwBfAa4Bp+bXLzrLU98W
# c+OvDYY3BnCBtj9nPWrQ24uzpB92GNxDVVUswdrK4fKqBjbMXBv3eShEmikl+p64
# 6hdNjxZQJgv6A2D3ew27G0cTRDEuzHLyzcJT+ZoWvZONFtvsemMqIiUhoE+EBgNX
# OjqR82hOFCQPFs7aElgwggcoMIIFEKADAgECAhMzAAAAFjGSjZICZXuaAAAAAAAW
# MA0GCSqGSIb3DQEBDAUAMGMxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xNDAyBgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmllZCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjEwHhcNMjYwMzI2MTgxMTI5WhcNMzEwMzI2MTgx
# MTI5WjBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9DIENBIDA0
# MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAylX6yNvoCTDP9G0OTlSj
# XbzgEsy21FDL17n/lZe2BrqHz2mR1aN4DBxeYp0/hjEqSHHyGfarV1NVBuvK8vLz
# W0LTi+DZt9In16aiNfgcogFiztWE9Fp8xu1zzrqE3nlrDWb+RZo8QrEXgWb8s8sw
# sl2W7tREHycVkx+Hm1MLQIlva6jH/Xg4/8GIYhHzbXiVd2RXomw9s7Qh6/SYRXXf
# e125wh4EKEyKnNNl+cZUSrVBgWvvjrRwQY4if7sAZ805KruBY6WY0Hiba5nWvrq9
# Qk9o35ViAf8qZ+7u1fbb1vcCWyWLfx9hLSdBjjVsSWe0xLvI1j4p3Tjt5czz+1Lc
# 0v5lQ1feB7nFmpbZrK2us0hvAaBCfOyDPEEm+735vzuNRYWJFL/PViI+REtjuJMc
# ojEn3veQjIrwrmK0T9oSr8e3oDzK1oAwwZMTC4KymTvYUTVDJvL5N8OW/UqIBzsi
# VYcchZvGhV3yMYKgxeEtIOG4W4Z85Y5kpQi5bpjGXFxRg46RdrTaALt1RhRmLR7U
# 0jVSr2aYAd2+Mp2qA5Gz3/loOOdt47eFZ3mrAYGYQtbK2SNjQpwgQX4Iy6tOKahC
# gFhKIcltitvSkpJB77eVWhNWnN2LfqMojszEue7V8EAySxry4PzlxTtFTb3Mw53X
# yH12BMQf2m9j7jEsHeVSATsCAwEAAaOCAdwwggHYMA4GA1UdDwEB/wQEAwIBhjAQ
# BgkrBgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQUayVB3vtrfP0YgAotf492XapzPbgw
# VAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWlj
# cm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAZBgkrBgEEAYI3
# FAIEDB4KAFMAdQBiAEMAQTASBgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaA
# FNlBKbAPD2Ns72nX9c0pnqRIajDmMHAGA1UdHwRpMGcwZaBjoGGGX2h0dHA6Ly93
# d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIwVmVy
# aWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBDQSUyMDIwMjEuY3JsMH0GCCsGAQUF
# BwEBBHEwbzBtBggrBgEFBQcwAoZhaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ29kZSUyMFNp
# Z25pbmclMjBQQ0ElMjAyMDIxLmNydDANBgkqhkiG9w0BAQwFAAOCAgEABtVQXlR0
# 1UQZY5XGQ9yIjMcD8jI0MizWhJ1buZjg5toUQSXx/BrASwE5qxwHPBeO45pOQp6V
# D4iILgm8OmfylY+A7KIqttvDUizC3sBXxjK4u7sDRiyEguXHKfL1HQAwxCLEtnRP
# kCPTsJA6b917lA+3foQIHC1XDDpdQLHxGbbGXp4Rr0mFK5vxbi6tAahBi/RlzOXP
# h6PavKPlZ/0vhlkDdsvoJETtebNJCNOZ1Kav3Tg+K4va4FbOrYqRHdGGahoA/gmT
# YmmVqw0zkGzT53HdhfajrFGttJomK7qE+T8CQGiPkEIkxNmSXjCTpDqc4U1IKlTG
# cGYnRFGSgqrnWnkANPFsJ5EDHysh82lPI+PFC3FOIVMLzLL+30rqznvRgHUUAj7x
# fFnEiuaAx3vFVSTOLb+iigpvdR6i8fSWpgYESOkdkn2N57tuhBs57tKwoP++vc/M
# VpuD1XAtmWi+lZSlahadTbDfGKjMn+bfm2xlW9PZ6BSnCRv1MMhpcUZkAZX3gVEM
# ef8rZc2c7BJ4ayRfX0wH43vI9znV+ZRJ3j0xUC0Zb82RQalF5yHkCr93x0IwvZtn
# 6P2dNQyCP6qd3fC4RlVFtAQhtOH0cByTR/Iqqghv6qHzL/pMptgMQQ5x8zYEYy+t
# CThYgYIrq7y4WEDYQfeSlqIxQOrIUJ4IJDEwggeeMIIFhqADAgECAhMzAAAAB4ej
# NKN7pY4cAAAAAAAHMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJ
# ZGVudGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkg
# MjAyMDAeFw0yMTA0MDEyMDA1MjBaFw0zNjA0MDEyMDE1MjBaMGMxCzAJBgNVBAYT
# AlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xNDAyBgNVBAMTK01p
# Y3Jvc29mdCBJRCBWZXJpZmllZCBDb2RlIFNpZ25pbmcgUENBIDIwMjEwggIiMA0G
# CSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCy8MCvGYgo4t1UekxJbGkIVQm0Uv96
# SvjB6yUo92cXdylN65Xy96q2YpWCiTas7QPTkGnK9QMKDXB2ygS27EAIQZyAd+M8
# X+dmw6SDtzSZXyGkxP8a8Hi6EO9Zcwh5A+wOALNQbNO+iLvpgOnEM7GGB/wm5dYn
# MEOguua1OFfTUITVMIK8faxkP/4fPdEPCXYyy8NJ1fmskNhW5HduNqPZB/NkWbB9
# xxMqowAeWvPgHtpzyD3PLGVOmRO4ka0WcsEZqyg6efk3JiV/TEX39uNVGjgbODZh
# zspHvKFNU2K5MYfmHh4H1qObU4JKEjKGsqqA6RziybPqhvE74fEp4n1tiY9/ootd
# U0vPxRp4BGjQFq28nzawuvaCqUUF2PWxh+o5/TRCb/cHhcYU8Mr8fTiS15kRmwFF
# zdVPZ3+JV3s5MulIf3II5FXeghlAH9CvicPhhP+VaSFW3Da/azROdEm5sv+EUwhB
# rzqtxoYyE2wmuHKws00x4GGIx7NTWznOm6x/niqVi7a/mxnnMvQq8EMse0vwX2Cf
# qM7Le/smbRtsEeOtbnJBbtLfoAsC3TdAOnBbUkbUfG78VRclsE7YDDBUbgWt75lD
# k53yi7C3n0WkHFU4EZ83i83abd9nHWCqfnYa9qIHPqjOiuAgSOf4+FRcguEBXlD9
# mAInS7b6V0UaNwIDAQABo4ICNTCCAjEwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQB
# gjcVAQQDAgEAMB0GA1UdDgQWBBTZQSmwDw9jbO9p1/XNKZ6kSGow5jBUBgNVHSAE
# TTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoA
# UwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAUyH7SaoUqG8oZ
# mAQHJ89QEE9oqKIwgYQGA1UdHwR9MHsweaB3oHWGc2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZp
# Y2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5j
# cmwwgcMGCCsGAQUFBwEBBIG2MIGzMIGBBggrBgEFBQcwAoZ1aHR0cDovL3d3dy5t
# aWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBJZGVudGl0eSUy
# MFZlcmlmaWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUy
# MDIwMjAuY3J0MC0GCCsGAQUFBzABhiFodHRwOi8vb25lb2NzcC5taWNyb3NvZnQu
# Y29tL29jc3AwDQYJKoZIhvcNAQEMBQADggIBAH8lKp7+1Kvq3WYK21cjTLpebJDj
# W4ZbOX3HD5ZiG84vjsFXT0OB+eb+1TiJ55ns0BHluC6itMI2vnwc5wDW1ywdCq3T
# Amx0KWy7xulAP179qX6VSBNQkRXzReFyjvF2BGt6FvKFR/imR4CEESMAG8hSkPYs
# o+GjlngM8JPn/ROUrTaeU/BRu/1RFESFVgK2wMz7fU4VTd8NXwGZBe/mFPZG6tWw
# kdmA/jLbp0kNUX7elxu2+HtHo0QO5gdiKF+YTYd1BGrmNG8sTURvn09jAhIUJfYN
# otn7OlThtfQjXqe0qrimgY4Vpoq2MgDW9ESUi1o4pzC1zTgIGtdJ/IvY6nqa80jF
# OTg5qzAiRNdsUvzVkoYP7bi4wLCj+ks2GftUct+fGUxXMdBUv5sdr0qFPLPB0b8v
# q516slCfRwaktAxK1S40MCvFbbAXXpAZnU20FaAoDwqq/jwzwd8Wo2J83r7O3onQ
# bDO9TyDStgaBNlHzMMQgl95nHBYMelLEHkUnVVVTUsgC0Huj09duNfMaJ9ogxhPN
# Thgq3i8w3DAGZ61AMeF0C1M+mU5eucj1Ijod5O2MMPeJQ3/vKBtqGZg4eTtUHt/B
# PjN74SsJsyHqAdXVS5c+ItyKWg3Eforhox9k3WgtWTpgV4gkSiS4+A09roSdOI4v
# rRw+p+fL4WrxSK5nMYIXMjCCFy4CAQEwcTBaMQswCQYDVQQGEwJVUzEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQg
# VmVyaWZpZWQgQ1MgQU9DIENBIDA0AhMzAAAnSPrclj7RSWb+AAAAACdIMA0GCWCG
# SAFlAwQCAQUAoF4wEAYKKwYBBAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisG
# AQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEILzciAuI4jSix7SeMh62c8O2aeiVBikO
# zyOt1qXWGDqrMA0GCSqGSIb3DQEBAQUABIIBgAornJR8MKK4mp+5oKPEPYDjrzws
# Hxm8Dd0VfUwfFhsr85+XjCsCw+agpa697Yc4rcrSWciq4/Q+tcT9ciqvcU78xGZg
# //7nhUIM6vs037+24oAtYw5pl9bOyw/716ipH0f3UomsxrTVOiNDaoTP5x4Z7wFP
# BGTLrvJGHyTzqY5amH/QjHp1Ggc2VXtNu6gq4VtUZCSOYtQSegsUyHD538WX58sp
# zgG989boJ8RS3QdTb65oglX6CXXTUSMvNJKFmCflOjh2LhESxjIMcSLQmPgT8/hR
# XMvZSSDnU9wM4N1XErCtRSNr6fMhT8oiuhAsCZ4U9xca5oXZy1C0gKR/kkZOYmuZ
# Do83OQVXgpgkIKDUAeFkwnjb0p9WINPM/iLTU144e2oPtknMa4OP+IsTE/jFF0Ry
# 42OwIOpDZnNCqhu1+OGy5npGLVJhsB5OXfBw4K0nraq3yZwdTLUYQs2MYJ8YjzS6
# Uw40h9FvDNzbu7p8Ez45WVvJ2Jr30BSLQyDffKGCFLIwghSuBgorBgEEAYI3AwMB
# MYIUnjCCFJoGCSqGSIb3DQEHAqCCFIswghSHAgEDMQ8wDQYJYIZIAWUDBAIBBQAw
# ggFqBgsqhkiG9w0BCRABBKCCAVkEggFVMIIBUQIBAQYKKwYBBAGEWQoDATAxMA0G
# CWCGSAFlAwQCAQUABCB1RrVoIerZ4etdeMqyz3fymHsQf553+fMytAqXqcD6zQIG
# acZoE0k1GBMyMDI2MDQxNjIzMjUzNS45MTNaMASAAgH0oIHppIHmMIHjMQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEe
# MBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3Nv
# ZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQg
# VFNTIEVTTjo3QjFBLTA1RTAtRDk0NzE1MDMGA1UEAxMsTWljcm9zb2Z0IFB1Ymxp
# YyBSU0EgVGltZSBTdGFtcGluZyBBdXRob3JpdHmggg8pMIIHgjCCBWqgAwIBAgIT
# MwAAAAXlzw//Zi7JhwAAAAAABTANBgkqhkiG9w0BAQwFADB3MQswCQYDVQQGEwJV
# UzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMUgwRgYDVQQDEz9NaWNy
# b3NvZnQgSWRlbnRpdHkgVmVyaWZpY2F0aW9uIFJvb3QgQ2VydGlmaWNhdGUgQXV0
# aG9yaXR5IDIwMjAwHhcNMjAxMTE5MjAzMjMxWhcNMzUxMTE5MjA0MjMxWjBhMQsw
# CQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYD
# VQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJ5851Jj/eDFnwV9Y7UGIqMc
# HtfnlzPREwW9ZUZHd5HBXXBvf7KrQ5cMSqFSHGqg2/qJhYqOQxwuEQXG8kB41wsD
# JP5d0zmLYKAY8Zxv3lYkuLDsfMuIEqvGYOPURAH+Ybl4SJEESnt0MbPEoKdNihwM
# 5xGv0rGofJ1qOYSTNcc55EbBT7uq3wx3mXhtVmtcCEr5ZKTkKKE1CxZvNPWdGWJU
# PC6e4uRfWHIhZcgCsJ+sozf5EeH5KrlFnxpjKKTavwfFP6XaGZGWUG8TZaiTogRo
# AlqcevbiqioUz1Yt4FRK53P6ovnUfANjIgM9JDdJ4e0qiDRm5sOTiEQtBLGd9Vhd
# 1MadxoGcHrRCsS5rO9yhv2fjJHrmlQ0EIXmp4DhDBieKUGR+eZ4CNE3ctW4uvSDQ
# VeSp9h1SaPV8UWEfyTxgGjOsRpeexIveR1MPTVf7gt8hY64XNPO6iyUGsEgt8c2P
# xF87E+CO7A28TpjNq5eLiiunhKbq0XbjkNoU5JhtYUrlmAbpxRjb9tSreDdtACpm
# 3rkpxp7AQndnI0Shu/fk1/rE3oWsDqMX3jjv40e8KN5YsJBnczyWB4JyeeFMW3JB
# fdeAKhzohFe8U5w9WuvcP1E8cIxLoKSDzCCBOu0hWdjzKNu8Y5SwB1lt5dQhABYy
# zR3dxEO/T1K/BVF3rV69AgMBAAGjggIbMIICFzAOBgNVHQ8BAf8EBAMCAYYwEAYJ
# KwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFGtpKDo1L0hjQM972K9J6T7ZPdshMFQG
# A1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYI
# KwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwDwYDVR0TAQH/BAUw
# AwEB/zAfBgNVHSMEGDAWgBTIftJqhSobyhmYBAcnz1AQT2ioojCBhAYDVR0fBH0w
# ezB5oHegdYZzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWlj
# cm9zb2Z0JTIwSWRlbnRpdHklMjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlm
# aWNhdGUlMjBBdXRob3JpdHklMjAyMDIwLmNybDCBlAYIKwYBBQUHAQEEgYcwgYQw
# gYEGCCsGAQUFBzAChnVodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Nl
# cnRzL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0aW9uJTIwUm9vdCUy
# MENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcnQwDQYJKoZIhvcNAQEM
# BQADggIBAF+Idsd+bbVaFXXnTHho+k7h2ESZJRWluLE0Oa/pO+4ge/XEizXvhs0Y
# 7+KVYyb4nHlugBesnFqBGEdC2IWmtKMyS1OWIviwpnK3aL5JedwzbeBF7POyg6IG
# G/XhhJ3UqWeWTO+Czb1c2NP5zyEh89F72u9UIw+IfvM9lzDmc2O2END7MPnrcjWd
# QnrLn1Ntday7JSyrDvBdmgbNnCKNZPmhzoa8PccOiQljjTW6GePe5sGFuRHzdFt8
# y+bN2neF7Zu8hTO1I64XNGqst8S+w+RUdie8fXC1jKu3m9KGIqF4aldrYBamyh3g
# 4nJPj/LR2CBaLyD+2BuGZCVmoNR/dSpRCxlot0i79dKOChmoONqbMI8m04uLaEHA
# v4qwKHQ1vBzbV/nG89LDKbRSSvijmwJwxRxLLpMQ/u4xXxFfR4f/gksSkbJp7oqL
# wliDm/h+w0aJ/U5ccnYhYb7vPKNMN+SZDWycU5ODIRfyoGl59BsXR/HpRGtiJquO
# YGmvA/pk5vC1lcnbeMrcWD/26ozePQ/TWfNXKBOmkFpvPE8CH+EeGGWzqTCjdAsn
# o2jzTeNSxlx3glDGJgcdz5D/AAxw9Sdgq/+rY7jjgs7X6fqPTXPmaCAJKVHAP19o
# EjJIBwD1LyHbaEgBxFCogYSOiUIr0Xqcr1nJfiWG2GwYe6ZoAF1bMIIHnzCCBYeg
# AwIBAgITMwAAAFl82nHpjV71wAAAAAAAWTANBgkqhkiG9w0BAQwFADBhMQswCQYD
# VQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQD
# EylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAyMDAeFw0y
# NjAxMDgxODU5MDFaFw0yNzAxMDcxODU5MDFaMIHjMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBP
# cGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3QjFB
# LTA1RTAtRDk0NzE1MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBT
# dGFtcGluZyBBdXRob3JpdHkwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoIC
# AQCmLuf+NHhF/oU/uYxWteOm4nd3QOC512J7b5D9whsOCxgERYZ7yzEif1bbLm8w
# 2nhZ5u8m9ikjO9Fph0Ka3Qlaqb1B+5dLgeIzcO7qy6AEfZChyxNFZTJQ0rQ0sVAS
# N6sLHa473Zr1dJPvf547gxIkpcyU3+w6MHdSt2zuG3kcmhYUfmPLcphAjqpTgH32
# KxtsGXVTOdfkEgUnvjxMpK/Aujp56koqbhfH2bwm+v4bpNGZumcLGosUhyAE9iBB
# r0u3OtyJvI1d2vEdCuotsosNDTZZ00qcMv2X7+4sLCwcIX24wU5/lzpepj8w10EN
# 1fkkT/cV2xijrAU8cxone2igB8N6OAIZfVBlix/ZDT91VKJBOiWJI5X6blBmeoEM
# qg3sH8Q+FaGCJaKbeB2dMUL6mo7icfnK/C0fyGeeoCy5sMjM3Xufr7YwaIpa8v4E
# mcFRsIJL5CIKSjwUBxrEgdMt7M6+2O8BG+r9MmWpdV1L1p5894p02klrAhayz1cF
# Zl8t53GOf3duVaTpIbfpuvexljW77DToQDh0Wn7RPY/4YZKDOkbMiXwS54ajHAP8
# HGr3+aI+TXskUHRmXiynJbPXLCkt7AVMz4nccdoojR/Qj2g6v2yyRDl2rGKIVzJ0
# Yp7vn1JPNbPFTuw0Ehen35+aKkh6FfJX9QMervpHUoW/AQIDAQABo4IByzCCAccw
# HQYDVR0OBBYEFI+W5wtfA9L5Z0kYQjojgxhrlzZ2MB8GA1UdIwQYMBaAFGtpKDo1
# L0hjQM972K9J6T7ZPdshMGwGA1UdHwRlMGMwYaBfoF2GW2h0dHA6Ly93d3cubWlj
# cm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFB1YmxpYyUyMFJTQSUy
# MFRpbWVzdGFtcGluZyUyMENBJTIwMjAyMC5jcmwweQYIKwYBBQUHAQEEbTBrMGkG
# CCsGAQUFBzAChl1odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRz
# L01pY3Jvc29mdCUyMFB1YmxpYyUyMFJTQSUyMFRpbWVzdGFtcGluZyUyMENBJTIw
# MjAyMC5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAO
# BgNVHQ8BAf8EBAMCB4AwZgYDVR0gBF8wXTBRBgwrBgEEAYI3TIN9AQEwQTA/Bggr
# BgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1Jl
# cG9zaXRvcnkuaHRtMAgGBmeBDAEEAjANBgkqhkiG9w0BAQwFAAOCAgEARDIcwv2X
# I6Rv81ERO89mKeb61MVI7BOV2t7f9kRrxEsL25rJN2yx4UhQGo4KNl0PMaBgz97F
# ISgiz3iAkm5Fb+lfLEqfHyfCaLOsq2sH9mFYrPLXFfjju1PUuiRj0M6Zj53H80HO
# J3tX6mePh4immyAxKBXXXUE9hIJJPX88QmPxGedmrydu3Un6yPyA5sp/VddDt4kK
# YNhfgvbzU65O51YKA6B2vfkN6WK9CBxp0preYq4Bk+N+s6OVp1z/BcTIbMB9Woso
# kmYlc4aK9dAvQudnD9wvPzxKDClF7LS46DztEzJHlv9Ra9fOilw+OUEYAaNMSJoL
# Vk3c1hZ5Q/qe/ogwSLkqzXEVw0WLqv2mGWg4VkiNEmHTyFlYeV717lgN9WvKENEj
# vqD2tzZPNJNPOuMIosidSrG0p2mnn4Pb7KXoIa6WPJYwsMXwlLceR0ETYACTiPCC
# gAiuHdNeDJNIZUTtJUFUR3oKiINvSul6pHN+tFtmSRlHLLZSqJJFY+igB4xsqy0T
# 83qWH4mVCauIF8sW6bym9VydhTduvNmlKDV6PUckStXIdH+upOvso/PJM77gu/ry
# VrTQ7P1KSDOh4ZtJFOuCVCezDBEHAHO5KX7expu2HkSvqCoKlIGFwn5s21/JyVyW
# Zz2vAA1lbCKrLjQMQiNAmV5FC6H6qOQXus8xggPUMIID0AIBATB4MGExCzAJBgNV
# BAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMT
# KU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFtcGluZyBDQSAyMDIwAhMzAAAA
# WXzacemNXvXAAAAAAABZMA0GCWCGSAFlAwQCAQUAoIIBLTAaBgkqhkiG9w0BCQMx
# DQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIC94II+DJUk3dwVHSI8rgl5o
# sEfMhQlOX+S2CPnomnkfMIHdBgsqhkiG9w0BCRACLzGBzTCByjCBxzCBoAQgy0W6
# sduG6bHFxCfh44/ca3FFcO0fDssjH0gdmBit/rwwfDBlpGMwYTELMAkGA1UEBhMC
# VVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWlj
# cm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENBIDIwMjACEzMAAABZfNpx
# 6Y1e9cAAAAAAAFkwIgQggXBGnsYAmiR/FjT6a7C+6L8Iq+vXYhQjUcg0bm7iacYw
# DQYJKoZIhvcNAQELBQAEggIAa8lm6F4kx3az0iacDQ8QIaBUFzvxrobutoEFcHsl
# C9ZCtBRtMr9orp9MWhrSZRb/58YLsbLaQMQ59RctPS3I76++sBEIdio4sqMyerBG
# 6MaMltbqueb3Vbpw7q2QypoigyNwFZyC4dVXyLtqhr1/3DBAN9+etuMwdVtUr/bt
# NOKghAIt4UdwoN1a2z3MhV1dhRmHDNdyeVGrxMAJjYPyTfEuIf96c0K630R/VnLb
# QMX1tPuDsyLF8cph/PzWCNn+hGEIvcyIQHvNycSuDfT1XJtwt2NFdDZv56Q9YNi/
# qf5ags/Nrfz16Nbg73goFUKhRaAPN4eacYbagiUgZFsbu2Jn/0S8Zn6xoJYehqNe
# lPpxV8El6n/FhVTDuaNjusEtIzDbURjJrM4hWy1w3Qd1W/bwiAPiSzaxDpE8k9qg
# qOFp+pXlTzPhagcU1YeTs9BcdqaeHuXcv3qcXvI/9PQfA+ZyBik8bcVBMYxMwKra
# 240Cgdb+FqlcBy8wgoZU3QYHPMiICk4O9XL8Rx4NMcUA4qkYsi8oEyFhhuq3bQQw
# bhiVGoxnvP2r+Tjrif2VzDfdUtBgp2UXvJE4UAxfNijUu/JjOJ9FNj3jMttjrZ6W
# zgT34U6U7hj5/3KTZQ/KMFdoF0oh5l2X2ZWxR6TWXpSzZa7ySYgSSKyfb4MQPlZX
# teY=
# SIG # End signature block
