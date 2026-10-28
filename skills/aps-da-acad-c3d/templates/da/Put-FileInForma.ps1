#Requires -Version 7
<#
.SYNOPSIS
    Uploads a local file into an ACC / Forma folder: a new file, or a new version if the name exists.

.DESCRIPTION
    Use this when the result is already on disk (for example workitem-results\layers.json) and only
    needs to go into the same folder as the drawing, without running a WorkItem again. It signs in as
    the Secure Service Account, which needs upload and edit permission on the folder (run
    Test-FormaAccess.ps1 -Write first). Needs the five values in .env. Prints no tokens or URLs.

.PARAMETER Link
    ACC or Forma folder link containing the project guid and folderUrn.

.PARAMETER File
    Path of the local file to upload.

.PARAMETER RemoteName
    Name in Forma. Defaults to the local file name; to match Run-FormaWorkItem.ps1 -PutBack, pass
    <drawing name without extension>-<file name>, for example city-planning-layers.json.

.EXAMPLE
    .\Put-FileInForma.ps1 -Link "<ACC folder link>" -File .\workitem-results\layers.json -RemoteName city-planning-layers.json
#>
param(
    [Parameter(Mandatory)] [string] $Link,
    [Parameter(Mandatory)] [string] $File,
    [string] $RemoteName
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\APS-Common.ps1"

if (-not (Test-Path $File)) { throw "File not found: $File" }
$uri = [Uri]$Link
if ($uri.AbsolutePath -notmatch 'projects/([0-9a-fA-F-]{36})') { throw "No project guid in link." }
$projectId = "b.$($Matches[1])"
$folderUrn = [System.Web.HttpUtility]::ParseQueryString($uri.Query)["folderUrn"]
if (-not $folderUrn) { throw "Link has no folderUrn. Pass the folder link." }
if (-not $RemoteName) { $RemoteName = Split-Path $File -Leaf }

$ssaToken = Get-SsaToken "data:read data:write data:create"
Write-Host "-- Putting '$RemoteName' into the folder --"
Publish-FileToAccFolder $ssaToken $projectId $folderUrn $File $RemoteName | Out-Null
Write-Host "Done." -ForegroundColor Green
