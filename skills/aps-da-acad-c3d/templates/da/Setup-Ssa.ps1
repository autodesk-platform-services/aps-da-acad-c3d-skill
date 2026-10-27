<#
.SYNOPSIS
    One-time setup of a Secure Service Account (SSA) for reading ACC / Forma files.

.DESCRIPTION
    Creates (or reuses) an SSA for your APS app, creates a key, saves the private key as a PEM file
    OUTSIDE the project, and writes the three APS_SSA_* values into .env. Run it yourself in your
    own shell. It prints no secrets: no token, no private key. The only thing it asks you to copy
    is the SSA email, which a project admin adds to the ACC / Forma project.

    Needs APS_CLIENT_ID and APS_CLIENT_SECRET in .env (see .env.example). PowerShell 7+.
    The private key is returned by APS only once. If the PEM is lost, rerun this script to create
    a new key.

.PARAMETER Name
    SSA name; the email becomes <Name>@<client id>.adskserviceaccount.com. Letters, digits, dash.

.PARAMETER KeyDir
    Folder for the PEM file. Keep it outside any git repository.

.EXAMPLE
    .\Setup-Ssa.ps1 -WhatIf       # shows what would happen, changes nothing
    .\Setup-Ssa.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[A-Za-z0-9-]{3,30}$')]
    [string] $Name = "da-ssa",
    [string] $FirstName = "Design",
    [string] $LastName = "Automation",
    [string] $KeyDir = (Join-Path $HOME ".aps"),
    [string] $EnvPath = (Join-Path $PSScriptRoot ".env")
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\APS-Common.ps1"   # also loads .env into the process environment

foreach ($v in "APS_CLIENT_ID", "APS_CLIENT_SECRET") {
    if (-not [Environment]::GetEnvironmentVariable($v)) { throw "Missing $v. Fill it in $EnvPath first (copy .env.example)." }
}
if (-not (Test-Path $EnvPath)) { throw "$EnvPath not found. Copy .env.example to .env first." }

# Refuse a key folder inside a git work tree: a PEM there can be committed by accident.
$probe = $KeyDir
while ($probe -and -not (Test-Path $probe)) { $probe = Split-Path $probe -Parent }
if ($probe -and (Get-Command git -ErrorAction SilentlyContinue) -and (git -C $probe rev-parse --is-inside-work-tree 2>$null) -eq "true") {
    throw "KeyDir '$KeyDir' is inside a git repository. Pick a folder outside it."
}

$authBase = "https://developer.api.autodesk.com/authentication/v2"
$scopes = "application:service_account:read application:service_account:write application:service_account_key:read application:service_account_key:write"
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($env:APS_CLIENT_ID):$($env:APS_CLIENT_SECRET)"))
$tokenResponse = Invoke-RestMethod -Method Post -Uri "$authBase/token" -Headers @{ Authorization = "Basic $basic" } `
    -ContentType "application/x-www-form-urlencoded" -Body @{ grant_type = "client_credentials"; scope = $scopes }
$h = @{ Authorization = "Bearer $($tokenResponse.access_token)" }

# Reuse the account when the name already exists (the account email starts with "<name>@").
$accounts = (Invoke-RestMethod -Method Get -Uri "$authBase/service-accounts" -Headers $h).serviceAccounts
$account = $accounts | Where-Object { $_.email -like "$Name@*" } | Select-Object -First 1
if ($account) {
    Write-Host "Reusing existing service account '$Name'." -ForegroundColor Cyan
} elseif ($PSCmdlet.ShouldProcess("service account '$Name'", "Create")) {
    $account = Invoke-RestMethod -Method Post -Uri "$authBase/service-accounts" -Headers $h -ContentType "application/json" `
        -Body (@{ name = $Name; firstName = $FirstName; lastName = $LastName } | ConvertTo-Json)
    Write-Host "Created service account '$Name'." -ForegroundColor Green
} else {
    return
}

# If .env already points at a key whose PEM exists, nothing more to do.
$currentKeyPath = $env:APS_SSA_PRIVATE_KEY_PATH
if ($env:APS_SSA_KEY_ID -and $currentKeyPath -and (Test-Path $currentKeyPath) -and
    $env:APS_SSA_SERVICE_ACCOUNT_ID -eq $account.serviceAccountId) {
    Write-Host "A key is already configured and its PEM exists. Nothing to change." -ForegroundColor Cyan
    Write-Host "SSA email (give to the project admin): $($account.email)"
    return
}

if ($PSCmdlet.ShouldProcess("a new key for '$Name', saved under $KeyDir", "Create")) {
    $key = Invoke-RestMethod -Method Post -Uri "$authBase/service-accounts/$($account.serviceAccountId)/keys" -Headers $h
    if (-not $key.privateKey -or -not $key.kid) { throw "Key response had no kid or privateKey." }

    New-Item -ItemType Directory -Force $KeyDir | Out-Null
    $pemPath = Join-Path $KeyDir "$($key.kid).pem"
    if (Test-Path $pemPath) { throw "$pemPath already exists, refusing to overwrite it." }
    [IO.File]::WriteAllText($pemPath, $key.privateKey, (New-Object Text.UTF8Encoding($false)))
    # Remove inherited permissions; leave read/write for the current user only.
    icacls $pemPath /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not restrict permissions on $pemPath." }

    # Update the three keys in .env in place; add any that are missing. Other lines stay as they are.
    $updates = [ordered]@{
        APS_SSA_SERVICE_ACCOUNT_ID = $account.serviceAccountId
        APS_SSA_KEY_ID             = $key.kid
        APS_SSA_PRIVATE_KEY_PATH   = $pemPath
    }
    $lines = [Collections.Generic.List[string]](Get-Content $EnvPath)
    foreach ($k in $updates.Keys) {
        $i = -1
        for ($n = 0; $n -lt $lines.Count; $n++) { if ($lines[$n] -match "^\s*$k\s*=") { $i = $n; break } }
        if ($i -ge 0) { $lines[$i] = "$k=$($updates[$k])" } else { $lines.Add("$k=$($updates[$k])") }
    }
    Set-Content -Path $EnvPath -Value $lines -Encoding utf8

    Write-Host "Private key saved to $pemPath (current user only)." -ForegroundColor Green
    Write-Host "Updated APS_SSA_* in $EnvPath." -ForegroundColor Green
}

Write-Host ""
Write-Host "Next, a human has to do two things in ACC / Forma:" -ForegroundColor Yellow
Write-Host "  1. Account admin: add client id $env:APS_CLIENT_ID under Account Admin > Custom Integrations."
Write-Host "  2. Project admin: add this member with Docs access and permission on the input folder:"
Write-Host "       $($account.email)"
