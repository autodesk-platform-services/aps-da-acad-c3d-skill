#Requires -Version 7
<#
.SYNOPSIS
    Checks that the service account (SSA) can read a Forma folder, and prints the admin
    handoff when it cannot.

.DESCRIPTION
    Resolves the SSA from the shared .env values (see APS-Common.ps1, Resolve-SsaConfig), gets an
    SSA token, and lists the folder. Exit code 0 means access works and nothing is printed for an
    admin. Exit code 2 means the read failed: the script prints a ready-to-send request for the
    Forma account admin and project admin. A 403 cannot say whether the Custom Integration or the
    project membership is missing, so both are listed. The output has no tokens, keys or secrets
    (the client id is not a secret).

.PARAMETER Link
    Forma folder link containing the project guid and folderUrn.

.EXAMPLE
    .\Test-FormaAccess.ps1 -Link "<Forma folder link>"
#>
param(
    [Parameter(Mandatory)] [string] $Link,
    # Use when results will be put back into the folder: the admin message then asks for upload permission.
    [switch] $Write
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\APS-Common.ps1"

$uri = [Uri]$Link
$folderUrn = [System.Web.HttpUtility]::ParseQueryString($uri.Query)["folderUrn"]
if ($uri.AbsolutePath -notmatch 'projects/([0-9a-fA-F-]{36})' -or -not $folderUrn) {
    throw "The link needs a project guid and a folderUrn. Open the folder in Forma and copy that link."
}
$projectGuid = $Matches[1]

try {
    $ssaToken = Get-SsaToken "data:read"   # resolves or creates the SSA, then signs in as it
} catch {
    Write-Host "Could not sign in as the service account: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
$ssaEmail = "$($env:SSA_FIRST_NAME)-$($env:SSA_LAST_NAME)@$($env:APS_CLIENT_ID).adskserviceaccount.com"

try {
    Invoke-RestMethod -Uri "https://developer.api.autodesk.com/data/v1/projects/b.$projectGuid/folders/$([Uri]::EscapeDataString($folderUrn))/contents" `
        -Headers @{ Authorization = "Bearer $ssaToken" } | Out-Null
    Write-Host "Access verified: $ssaEmail can read the folder." -ForegroundColor Green
    exit 0
} catch {
    $status = $_.Exception.Response.StatusCode.value__
    Write-Host "The service account cannot read the folder (HTTP $status)." -ForegroundColor Yellow
    Write-Host "Two things must be in place. A 403 does not say which one is missing, so ask for both:"
    Write-Host ""
    Write-Host "----- Copy from here and send to your Forma admin -----"
    Write-Host "Hello, I am setting up an APS Design Automation app that reads drawings from this project."
    Write-Host "Please do these two things:"
    Write-Host ""
    Write-Host "1. Account admin: Account Admin > Settings > Custom Integrations > add a custom integration"
    Write-Host "   using this client id (it is an identifier, not a secret):"
    Write-Host "     $($env:APS_CLIENT_ID)"
    Write-Host ""
    Write-Host "2. Project admin: open the project > Members > Add members, add this service account email"
    $perm = if ($Write) { "Upload and Edit is needed, because results are put back into the folder" } else { "View and Download is enough to read" }
    Write-Host "   with Docs access, and give it permission on the folder ($perm):"
    Write-Host "     $ssaEmail"
    Write-Host "   Project: $projectGuid"
    Write-Host "   Folder:  $Link"
    Write-Host "----- End of message -----"
    Write-Host ""
    Write-Host "When your admin confirms, run this script again. It continues once access works."
    exit 2
}
