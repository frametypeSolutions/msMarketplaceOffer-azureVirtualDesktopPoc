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

# SIG # Begin signature block
# MII57gYJKoZIhvcNAQcCoII53zCCOdsCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAjzG6798vUvbaN
# qd1Ge0BUpeOEtCTqm/OpaM5H5HfmnqCCIhIwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# AQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEINZbkRbALLO6RUvA4zX8oVCu5Lu/3ZPO
# jI8qqw9DPyuPMA0GCSqGSIb3DQEBAQUABIIBgGGlNuDZQFkhsHZdRMLUo5pYA5Q2
# 7g3ZNtIFUYN3ZMBmbn8AXv9/nfdNjXK6yFdrgvXBsVltKDK/yywvJqd807DpWdt9
# +35JLnk7bQhZzDW5v7ClJlGdoMeeHDj5Bm7RIdM/S0BCJp1kKtRj1kvO0WwUP00f
# 6nOj4shMzlr9PvLnaRYiibDsz7J3f/ZwR1mVSkjZgsJ0VdfxLaC22gZx+/0C3g3e
# uPUyG5d1VIzjDTzqzr9yXWvHHb8FYydna569TfM489qIy9uGbC3B5t1mwgsMagA0
# KGUk6JVbpAlsAwE1sq2p1QTRZ7bOLG6KaEIewyHSJ7iFL0qxc0SIE9CO7RrASY84
# A6tr9jG1v6ZzPCGlHgTlLYec4amOueuN/XSBjVMaOcYQKLMsArFQ/PZozgEpOyJL
# 777Ko+ZjoLJVtc/RPLce6HFXiTqSBCgFnzCxMzBN5X1OvFUeLJQrjWXHUqLinLju
# g43iNAx5f5AuHPnN1ZnGE+fE8EaZkjtDnLdxL6GCFLIwghSuBgorBgEEAYI3AwMB
# MYIUnjCCFJoGCSqGSIb3DQEHAqCCFIswghSHAgEDMQ8wDQYJYIZIAWUDBAIBBQAw
# ggFqBgsqhkiG9w0BCRABBKCCAVkEggFVMIIBUQIBAQYKKwYBBAGEWQoDATAxMA0G
# CWCGSAFlAwQCAQUABCBHLx974UuyFwN0r/+UeEMtTs8BredmUjOdc0P5WVNacgIG
# acZoE0ksGBMyMDI2MDQxNjIzMjUyNy41NzFaMASAAgH0oIHppIHmMIHjMQswCQYD
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
# DQYLKoZIhvcNAQkQAQQwLwYJKoZIhvcNAQkEMSIEIIRM//eDt+jQuHV49wxhgprB
# OLeluMzLBUKpfwH/q+/GMIHdBgsqhkiG9w0BCRACLzGBzTCByjCBxzCBoAQgy0W6
# sduG6bHFxCfh44/ca3FFcO0fDssjH0gdmBit/rwwfDBlpGMwYTELMAkGA1UEBhMC
# VVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWlj
# cm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENBIDIwMjACEzMAAABZfNpx
# 6Y1e9cAAAAAAAFkwIgQggXBGnsYAmiR/FjT6a7C+6L8Iq+vXYhQjUcg0bm7iacYw
# DQYJKoZIhvcNAQELBQAEggIAMDZQ8+SyA8OvtUYCEJlP+NGGEYEe65hS+xZM38eh
# fxuiN67EjF5zDJ7Wsti1TZswD1+4DMNlAhXOws919oC6qcUdtjIJRaJ1vCia0LzB
# ZIn0ZsSoZZrce/t0mQChnX5IAVzQxMGZGOiVMFDv2uwC80XDn5m7ubL2yc/1Z5+M
# suB1qWPFnYauPF1wnDz3OFrjlKh/IEZm/bgXIQXJHnc8lBTF1KN1RsunwHPl941q
# bEUfDMj7ZueKG9sPhMYtpz3CKM3CD86KNfe2qh2p99SHFsRbiw2OD3wj/dfNXbf4
# QJ49cwfb5aaSyBl76zozmX8+jgRnkgTLfQdoH2cSrYJcN7ZYOnZNfwt2YnesSXnC
# 1IVP4NtYb92nh8x7EW0jVCdA6n4kGClhLvbMgtnukX0R9tBVx/E9kb3MbfRNO0V6
# CSvS/Sitg9lK/utkRhng+inBl/92674TUQYkQz1b/SMJYt6iPfQnbWgyTZPBcHGR
# LyKBQFvctg2RQ72tThS2RJwbQ2pMqnqD3+EEQu8jOxm/2GgzB0Mtbe7z04vM2Gz5
# g4tCfZOaOvs+WmaiPpl59GGupxCfoz65AsviYNyah2938mkx7JnmLyfj5lR7KWxR
# B85wIv/PQJ2mPqHjkCm1cT8ofHDj3KJMUt612T8gssJ4KEmN0swKAvdaetVCJaY3
# 3lw=
# SIG # End signature block
