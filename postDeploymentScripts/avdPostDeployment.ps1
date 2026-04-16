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
