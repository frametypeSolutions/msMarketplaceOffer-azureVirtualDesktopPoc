<#
.SYNOPSIS
    Pre-deployment prerequisite script for the frameType Solutions AVD Marketplace offer.

.DESCRIPTION
    Creates (or retrieves) two Entra ID security groups required by the Azure Virtual Desktop
    Marketplace offer before deployment. Outputs the Object IDs for pasting into the
    createUiDefinition.json wizard in the Azure Portal.

    Groups created:
      - avd-{env}-{region}-users   : AVD end users (Desktop Virtualization User, VM User Login)
      - avd-{env}-{region}-admins  : AVD administrators (Desktop Virtualization Contributor, VM Admin Login)

.PARAMETER Environment
    Short environment code (e.g. dev, test, prod). Used in group display names.

.PARAMETER Region
    Azure region short name (e.g. westus2, eastus). Used in group display names.

.PARAMETER OutputPath
    Optional. Path to write the avd-prerequisites.json sidecar file.
    Defaults to the current directory.

.EXAMPLE
    .\New-AvdPrerequisites.ps1
    Interactive mode — prompts for all inputs.

.EXAMPLE
    .\New-AvdPrerequisites.ps1 -Environment dev -Region westus2
    Non-interactive mode — uses supplied values, prompts only for confirmation.

.NOTES
    Requirements:
      - Azure CLI (az) version 2.50.0 or later
      - Account must hold one of: Global Administrator, Groups Administrator,
        User Administrator in Entra ID
      - Internet connectivity to login.microsoftonline.com and graph.microsoft.com

    Repository : https://github.com/frametypeSolutions/msMarketplaceBuild-azureVirtualDesktopPoc
    Author     : frameType Solutions
    Version    : 1.1.02
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Environment,

    [Parameter(Mandatory = $false)]
    [string]$Region,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Region: Helpers
# ---------------------------------------------------------------------------

function Write-Banner {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║     frameType Solutions — AVD Marketplace Pre-Deployment        ║" -ForegroundColor Cyan
    Write-Host "║     New-AvdPrerequisites.ps1  v1.1.02                            ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host "── $Title " -ForegroundColor Cyan -NoNewline
    Write-Host ("─" * ([Math]::Max(2, 60 - $Title.Length))) -ForegroundColor DarkGray
}

function Write-Success([string]$Message) { Write-Host "  ✔  $Message" -ForegroundColor Green }
function Write-Info([string]$Message)    { Write-Host "  ℹ  $Message" -ForegroundColor DarkCyan }
function Write-Warn([string]$Message)    { Write-Host "  ⚠  $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message)    { Write-Host "  ✖  $Message" -ForegroundColor Red }

function Read-TextDefault {
    param([string]$Prompt, [string]$Default)
    $in = Read-Host "$Prompt (Enter for '$Default')"
    if ([string]::IsNullOrWhiteSpace($in)) { return $Default }
    return $in.Trim()
}

function Invoke-GraphRest {
    param(
        [string]$Method = 'GET',
        [string]$Uri,
        [string]$Body = $null,
        [string]$BodyFile = $null
    )
    $args = @(
        'rest',
        '--method', $Method,
        '--uri', $Uri,
        '--headers', 'Content-Type=application/json'
    )
    if ($BodyFile) { $args += @('--body', "@$BodyFile") }
    elseif ($Body) { $args += @('--body', $Body) }

    $result = & az @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Graph API call failed ($Method $Uri): $result"
    }
    return $result | ConvertFrom-Json
}

# ---------------------------------------------------------------------------
# Region: Azure CLI version check
# ---------------------------------------------------------------------------

function Assert-AzCliVersion {
    Write-Section "Checking Azure CLI"
    try {
        $versionJson = az version --output json 2>&1 | ConvertFrom-Json
        $cliVersion  = $versionJson.'azure-cli'
        Write-Success "Azure CLI version: $cliVersion"

        $parts = $cliVersion -split '\.'
        $major = [int]$parts[0]
        $minor = [int]$parts[1]
        if ($major -lt 2 -or ($major -eq 2 -and $minor -lt 50)) {
            Write-Warn "Azure CLI 2.50.0 or later is recommended. Please run: az upgrade"
        }
    }
    catch {
        Write-Fail "Azure CLI not found or not in PATH."
        Write-Host "  Install from: https://aka.ms/installazurecliwindows" -ForegroundColor DarkGray
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Region: Authentication
# ---------------------------------------------------------------------------

function Invoke-AzLogin {
    Write-Section "Azure Authentication"
    Write-Info "Checking for existing Azure CLI session..."

    $accountJson = az account show --output json 2>&1
    if ($LASTEXITCODE -eq 0) {
        $account = $accountJson | ConvertFrom-Json
        Write-Success "Already signed in as: $($account.user.name)"
        Write-Info "Tenant : $($account.tenantId)"
        Write-Info "Sub    : $($account.name) ($($account.id))"

        $reuse = Read-Host "  Use this account? (Y/n)"
        if ($reuse -match '^[Nn]') {
            Write-Info "Signing in with a different account..."
            az login --output none
            if ($LASTEXITCODE -ne 0) { Write-Fail "az login failed."; exit 1 }
        }
    }
    else {
        Write-Info "No active session found. Launching interactive login..."
        az login --output none
        if ($LASTEXITCODE -ne 0) { Write-Fail "az login failed."; exit 1 }
    }

    # Capture final account details
    $script:AccountInfo = az account show --output json 2>&1 | ConvertFrom-Json
    Write-Success "Signed in as : $($script:AccountInfo.user.name)"
    Write-Success "Tenant ID    : $($script:AccountInfo.tenantId)"
}

function Invoke-GraphConsentGate {
    Write-Section "Acquiring Microsoft Graph Token"
    Write-Info "Requesting Graph-scoped access token (consent prompt may appear)..."

    az account get-access-token --resource https://graph.microsoft.com --output none 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to acquire a Graph token."
        Write-Host "  Ensure your account has consented to Microsoft Graph access." -ForegroundColor DarkGray
        exit 1
    }
    Write-Success "Graph token acquired successfully."
}

# ---------------------------------------------------------------------------
# Region: Role validation
# ---------------------------------------------------------------------------

function Assert-EntraRoles {
    Write-Section "Validating Entra ID Roles"

    $userId = $null
    try {
        $meJson = Invoke-GraphRest -Uri "https://graph.microsoft.com/v1.0/me?`$select=id,displayName,userPrincipalName"
        $userId = $meJson.id
        Write-Info "Signed-in user : $($meJson.displayName) ($($meJson.userPrincipalName))"
    }
    catch {
        Write-Warn "Could not resolve signed-in user identity via Graph: $_"
        Write-Warn "Proceeding without role validation — group creation may fail if roles are insufficient."
        return
    }

    # Roles that grant group creation rights
    $requiredRoleTemplateIds = @(
        '62e90394-69f5-4237-9190-012177145e10', # Global Administrator
        'fdd7a751-b60b-444a-984c-02652fe8fa1c', # Groups Administrator
        'fe930be7-5e62-47db-91af-98c3a49a38b1'  # User Administrator
    )
    $requiredRoleNames = @('Global Administrator', 'Groups Administrator', 'User Administrator')

    try {
        $rolesJson = Invoke-GraphRest -Uri "https://graph.microsoft.com/v1.0/me/memberOf/microsoft.graph.directoryRole?`$select=displayName,roleTemplateId"
        $assignedRoles = $rolesJson.value

        $matchedRole = $assignedRoles | Where-Object {
            $requiredRoleTemplateIds -contains $_.roleTemplateId
        } | Select-Object -First 1

        if ($matchedRole) {
            Write-Success "Required role confirmed: $($matchedRole.displayName)"
        }
        else {
            Write-Fail "The signed-in account does not hold a required Entra ID role."
            Write-Host ""
            Write-Host "  Required (one of):" -ForegroundColor Yellow
            $requiredRoleNames | ForEach-Object { Write-Host "    • $_" -ForegroundColor Yellow }
            Write-Host ""
            Write-Host "  Ask a Global Administrator to assign one of these roles, then re-run this script." -ForegroundColor DarkGray
            exit 1
        }
    }
    catch {
        Write-Warn "Role lookup failed: $_"
        Write-Warn "Proceeding without confirmed role validation."
    }
}

# ---------------------------------------------------------------------------
# Region: Group name inputs
# ---------------------------------------------------------------------------

function Get-GroupNames {
    Write-Section "Security Group Configuration"

    if ([string]::IsNullOrWhiteSpace($script:Environment)) {
        $script:Environment = Read-TextDefault -Prompt "Environment code (e.g. dev, test, prod)" -Default "dev"
    }
    if ([string]::IsNullOrWhiteSpace($script:Region)) {
        $script:Region = Read-TextDefault -Prompt "Azure region (e.g. westus2, eastus)" -Default "westus2"
    }

    $env    = $script:Environment.ToLower().Trim()
    $region = $script:Region.ToLower().Trim()

    $script:UsersGroupName  = Read-TextDefault `
        -Prompt "AVD Users group display name" `
        -Default "avd-$env-$region-users"

    $script:AdminsGroupName = Read-TextDefault `
        -Prompt "AVD Admins group display name" `
        -Default "avd-$env-$region-admins"

    Write-Host ""
    Write-Info "Users group  : $($script:UsersGroupName)"
    Write-Info "Admins group : $($script:AdminsGroupName)"
}

# ---------------------------------------------------------------------------
# Region: Idempotent group get-or-create
# ---------------------------------------------------------------------------

function Get-OrCreateGroup {
    param(
        [string]$DisplayName,
        [string]$Description
    )

    # Sanitise mailNickname
    $mailNick = ($DisplayName.ToLower() -replace '[^a-z0-9]', '')
    if ($mailNick.Length -gt 60)             { $mailNick = $mailNick.Substring(0, 60) }
    if ([string]::IsNullOrWhiteSpace($mailNick)) { $mailNick = "avdgroup" }

    $encodedName = [Uri]::EscapeDataString($DisplayName)

    # 1. Try find by displayName
    try {
        $existing = Invoke-GraphRest -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$DisplayName'&`$select=id,displayName"
        if ($existing.value -and $existing.value.Count -gt 0) {
            $group = $existing.value[0]
            Write-Warn "Existing group found  : $($group.displayName)"
            Write-Warn "Reusing Object ID     : $($group.id)"
            return $group.id
        }
    }
    catch {
        Write-Warn "displayName lookup failed for '$DisplayName': $_"
    }

    # 2. Try find by mailNickname
    try {
        $existing = Invoke-GraphRest -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=mailNickname eq '$mailNick'&`$select=id,displayName,mailNickname"
        if ($existing.value -and $existing.value.Count -gt 0) {
            $group = $existing.value[0]
            Write-Warn "Existing group found by mailNickname : $($group.displayName)"
            Write-Warn "Reusing Object ID                   : $($group.id)"
            return $group.id
        }
    }
    catch {
        Write-Warn "mailNickname lookup failed for '$mailNick': $_"
    }

    # 3. Create new group
    # Write body to a UTF-8 temp file — az rest passes inline body through Python's
    # requests library which defaults to latin-1, causing UnicodeEncodeError on any
    # non-ASCII characters (including em dashes, smart quotes, etc.) in descriptions.
    Write-Info "Creating group: $DisplayName"
    $bodyObject = @{
        displayName     = $DisplayName
        description     = $Description
        mailEnabled     = $false
        securityEnabled = $true
        mailNickname    = $mailNick
    }
    $tempFile = [System.IO.Path]::GetTempFileName() + ".json"
    $bodyObject | ConvertTo-Json -Compress | Set-Content -Path $tempFile -Encoding UTF8

    $newGroup = Invoke-GraphRest -Method 'POST' -Uri "https://graph.microsoft.com/v1.0/groups" -BodyFile $tempFile
    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue

    if ([string]::IsNullOrWhiteSpace($newGroup.id)) {
        throw "Group '$DisplayName' was created but returned an empty Object ID."
    }

    Write-Success "Created group : $($newGroup.displayName)"
    Write-Success "Object ID     : $($newGroup.id)"
    return $newGroup.id
}

# ---------------------------------------------------------------------------
# Region: Create both groups
# ---------------------------------------------------------------------------

function Invoke-CreateGroups {
    Write-Section "Creating Entra ID Security Groups"

    $script:UsersGroupObjectId = Get-OrCreateGroup `
        -DisplayName $script:UsersGroupName `
        -Description "AVD end users - Desktop Virtualization User, Virtual Machine User Login"

    $script:AdminsGroupObjectId = Get-OrCreateGroup `
        -DisplayName $script:AdminsGroupName `
        -Description "AVD administrators - Desktop Virtualization Contributor, Virtual Machine Administrator Login"
}

# ---------------------------------------------------------------------------
# Region: Output summary
# ---------------------------------------------------------------------------

function Write-OutputSummary {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║                  ✔  Prerequisites Complete                      ║" -ForegroundColor Green
    Write-Host "╠══════════════════════════════════════════════════════════════════╣" -ForegroundColor Green
    Write-Host "║  Paste these values into the AVD Marketplace deployment wizard  ║" -ForegroundColor Green
    Write-Host "╠══════════════════════════════════════════════════════════════════╣" -ForegroundColor Green
    Write-Host "║                                                                  ║" -ForegroundColor Green
    Write-Host "║  AVD Users Group Object ID                                       ║" -ForegroundColor Green
    Write-Host "║  $($script:UsersGroupObjectId.PadRight(64))║" -ForegroundColor White
    Write-Host "║                                                                  ║" -ForegroundColor Green
    Write-Host "║  AVD Admins Group Object ID                                      ║" -ForegroundColor Green
    Write-Host "║  $($script:AdminsGroupObjectId.PadRight(64))║" -ForegroundColor White
    Write-Host "║                                                                  ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Region: JSON sidecar
# ---------------------------------------------------------------------------

function Write-JsonSidecar {
    Write-Section "Writing Prerequisites Sidecar"

    $sidecar = [ordered]@{
        generatedAt          = (Get-Date -Format 'o')
        generatedBy          = $script:AccountInfo.user.name
        tenantId             = $script:AccountInfo.tenantId
        subscriptionId       = $script:AccountInfo.id
        subscriptionName     = $script:AccountInfo.name
        environment          = $script:Environment
        region               = $script:Region
        avdUsersGroupName    = $script:UsersGroupName
        avdUsersGroupObjectId  = $script:UsersGroupObjectId
        avdAdminsGroupName   = $script:AdminsGroupName
        avdAdminsGroupObjectId = $script:AdminsGroupObjectId
    }

    $outputFile = Join-Path $OutputPath "avd-prerequisites.json"

    try {
        $sidecar | ConvertTo-Json -Depth 5 | Set-Content -Path $outputFile -Encoding UTF8
        Write-Success "Sidecar written to: $outputFile"
        Write-Info "Keep this file — it records the group Object IDs for your deployment audit trail."
    }
    catch {
        Write-Warn "Could not write sidecar file to '$outputFile': $_"
        Write-Warn "The Object IDs above are still valid — note them manually if needed."
    }
}

# ---------------------------------------------------------------------------
# Region: Next steps
# ---------------------------------------------------------------------------

function Write-NextSteps {
    Write-Host ""
    Write-Host "  Next Steps" -ForegroundColor Cyan
    Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  1. Copy the two Object IDs from the green box above." -ForegroundColor White
    Write-Host "  2. Go to the Azure Marketplace and click 'Get It Now' on the" -ForegroundColor White
    Write-Host "     frameType Solutions AVD offer." -ForegroundColor White
    Write-Host "  3. In the deployment wizard, paste each ID into the" -ForegroundColor White
    Write-Host "     corresponding field on the Identity configuration step." -ForegroundColor White
    Write-Host "  4. Complete the remaining wizard steps and deploy." -ForegroundColor White
    Write-Host ""
    Write-Host "  Documentation : https://github.com/frametypeSolutions/msMarketplaceBuild-azureVirtualDesktopPoc" -ForegroundColor DarkGray
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Region: Entry point
# ---------------------------------------------------------------------------

Write-Banner
Assert-AzCliVersion
Invoke-AzLogin
Invoke-GraphConsentGate
Assert-EntraRoles
Get-GroupNames
Invoke-CreateGroups
Write-OutputSummary
Write-JsonSidecar
Write-NextSteps
