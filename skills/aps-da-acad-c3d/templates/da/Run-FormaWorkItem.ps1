#Requires -Version 7
<#
.SYNOPSIS
    Runs an activity on a drawing stored in ACC / Forma and saves the result locally (default
    activity LayerExtract, result layers.json; change with -Activity and -OutputName).

.DESCRIPTION
    Reads the drawing with a Secure Service Account (SSA), submits a signed WorkItem as that SSA, and
    puts the result into an OSS bucket, then downloads it to -OutDir. With -PutBack the result is also
    uploaded into the same Forma/ACC folder; with -ShowLink the time-limited download link is printed.
    Run Deploy-And-Test-DA.ps1 -DeployOnly first (it creates the AppBundle and Activity), and
    Test-FormaAccess.ps1. Needs the five values in .env. If mykey.json is missing it is generated and
    registered for the nickname (keep it out of git; the gitignore template covers it).
    Prints no tokens, keys, secrets or presigned URLs unless -ShowLink is given.

.EXAMPLE
    .\Run-FormaWorkItem.ps1
    Asks for the link, file name and every other option; Enter accepts the default shown in brackets.

.EXAMPLE
    .\Run-FormaWorkItem.ps1 -Link "<ACC folder link>" -FileName city-planning -Version 2 -PutBack
#>
param(
    [string] $Link,
    [string] $FileName,
    [int]    $Version = 0,                 # 0 = latest
    [string] $Alias   = "dev",
    [string] $Activity = "LayerExtract",
    [string] $OutputName = "layers.json",  # must match the activity's outputFile localName
    [string] $OutDir  = "$PSScriptRoot\workitem-results",
    # Also put the result into the same Forma/ACC folder as the drawing, as a new file or a new version.
    # Needs upload permission for the SSA on that folder.
    [switch] $PutBack,
    # Report completion over the Automation WebSocket API instead of polling GET workitems/:id.
    [switch] $UseWebSocket,
    # Print the time-limited download link for the result (it is a presigned URL, so keep it private).
    [switch] $ShowLink,
    [string] $RemoteName   # default: <drawing name without extension>-<OutputName>
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\APS-Common.ps1"
$DM = "https://developer.api.autodesk.com"

# --- Interactive mode -------------------------------------------------------------------------------
# Started without -Link or -FileName: ask for every option, Enter keeps the default in [brackets].
# Any option passed on the command line is not asked again. With both given the script never prompts,
# so scripted and Claude Code runs behave as before.
function Read-Option([string]$Prompt, [string]$Default) {
    $suffix = if ($Default) { " [$Default]" } else { "" }
    $answer = Read-Host "$Prompt$suffix"
    # Strip quotes people type around names with spaces (they are not part of the name).
    $answer = if ($answer) { $answer.Trim().Trim('"', "'") } else { "" }
    if ($answer) { $answer } else { $Default }
}
if (-not $Link -or -not $FileName) {
    if (-not [Environment]::UserInteractive) { throw "-Link and -FileName are required when not interactive." }
    if (-not $Link)     { $Link     = Read-Option "Forma folder link" "" }
    if (-not $FileName) { $FileName = Read-Option "Drawing file name (e.g. city-planning.dwg)" "" }
    if (-not $Link -or -not $FileName) { throw "Link and file name are required." }
    if (-not $PSBoundParameters.ContainsKey('Version'))    { $Version    = [int](Read-Option "Version (0 = latest)" "$Version") }
    if (-not $PSBoundParameters.ContainsKey('Activity'))   { $Activity   = Read-Option "Activity" $Activity }
    if (-not $PSBoundParameters.ContainsKey('Alias'))      { $Alias      = Read-Option "Alias" $Alias }
    if (-not $PSBoundParameters.ContainsKey('PutBack')) {
        $PutBack = (Read-Option "Put the result back into the same folder? (y/n)" "y") -match '^(y|yes)$'
    }
    if ($PutBack -and -not $PSBoundParameters.ContainsKey('RemoteName')) {
        $RemoteName = Read-Option "Name of the file in Forma" "$([IO.Path]::GetFileNameWithoutExtension($FileName))-$OutputName"
    }
}

# --- Parse the link: project guid, and either an entityId (file version) or a folderUrn -------------
$uri = [Uri]$Link
if ($uri.AbsolutePath -notmatch 'projects/([0-9a-fA-F-]{36})') { throw "No project guid in link." }
$projectId = "b.$($Matches[1])"
$query = [System.Web.HttpUtility]::ParseQueryString($uri.Query)
$folderUrn = $query["folderUrn"]
if (-not $folderUrn) { throw "Link has no folderUrn. Pass the folder link." }

# --- Tokens -----------------------------------------------------------------------------------------
$appToken = Get-APSToken                                   # 2-legged: DA admin calls, OSS bucket
$ssaScope = "data:read data:write code:all" + $(if ($PutBack) { " data:create" } else { "" })
$ssaToken = Get-SsaToken $ssaScope                         # 3-legged: read ACC file, submit WorkItem, put back
$owner = if ($env:APS_NICKNAME) { $env:APS_NICKNAME } else { Get-DANickname $appToken }
if (-not $owner) { throw "No DA nickname. Register one first (Register-DaSigningKey)." }

function Invoke-Dm([string]$path) {
    try { Invoke-RestMethod -Uri "$DM$path" -Headers @{ Authorization = "Bearer $ssaToken" } }
    catch { throw "GET $path -> $($_.Exception.Response.StatusCode): $($_.ErrorDetails.Message). 403 usually means the SSA email is not a project member with folder access." }
}

# --- Find the item in the folder --------------------------------------------------------------------
Write-Host "-- Locating '$FileName' --"
$enc = [Uri]::EscapeDataString($folderUrn)
$contents = Invoke-Dm "/data/v1/projects/$projectId/folders/$enc/contents?filter[type]=items&filter[displayName]-contains=$([Uri]::EscapeDataString($FileName))"
$items = @($contents.data)
if ($items.Count -eq 0) { throw "No item matching '$FileName' in the folder." }
if ($items.Count -gt 1) {
    $items | ForEach-Object { Write-Host "  candidate: $($_.attributes.displayName)" }
    throw "More than one match. Pass the exact name with -FileName."
}
$item = $items[0]
Write-Host "  $($item.attributes.displayName)"

# --- Pick the version -------------------------------------------------------------------------------
$versions = @((Invoke-Dm "/data/v1/projects/$projectId/items/$([Uri]::EscapeDataString($item.id))/versions").data)
$ver = if ($Version -gt 0) { $versions | Where-Object { $_.attributes.versionNumber -eq $Version } | Select-Object -First 1 }
       else { $versions | Sort-Object { $_.attributes.versionNumber } -Descending | Select-Object -First 1 }
if (-not $ver) { throw "Version $Version not found. Available: $(($versions.attributes.versionNumber | Sort-Object) -join ', ')." }
Write-Host "  using version $($ver.attributes.versionNumber)"

# --- Resolve the presigned download URL (do not fetch the legacy href directly) ----------------------
function Get-InputUrl {
    $href = [Uri]$ver.relationships.storage.meta.link.href
    $url  = "$($href.GetLeftPart([UriPartial]::Authority))$($href.AbsolutePath.TrimEnd('/'))/signeds3download$($href.Query)"
    $r = Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $ssaToken" }
    if (-not $r.url) { throw "signeds3download returned no url." }
    return $r.url
}

# --- Output: OSS bucket, written with a signed S3 upload URL ----------------------------------------
$bucketKey = "$($owner.ToLower())-layer-extract"
Ensure-OSSBucket $appToken $bucketKey
$objectKey = "$([IO.Path]::GetFileNameWithoutExtension($OutputName))-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))$([IO.Path]::GetExtension($OutputName))"
$encObj = [Uri]::EscapeDataString($objectKey)
$up = Invoke-RestMethod -Uri "$OSS_BASE/buckets/$bucketKey/objects/$encObj/signeds3upload?minutesExpiration=60&parts=1" `
    -Headers @{ Authorization = "Bearer $appToken" }

# --- Submit as the SSA, signed ----------------------------------------------------------------------
Write-Host "`n-- WorkItem --"
$activityId = "$owner.$Activity"
if (-not (Test-Path "$PSScriptRoot\mykey.json")) {
    Write-Host "  No signing key yet: generating one and registering it for nickname '$owner'." -ForegroundColor Yellow
    Register-DaSigningKey $appToken $owner
}
$signature  = Get-ActivitySignature "$activityId+$Alias"
$arguments = @{
    inputFile  = @{ url = (Get-InputUrl) }                 # expires in about 2 minutes: resolve last
    outputFile = @{ url = $up.urls[0]; verb = "put" }
}
if ($UseWebSocket) {
    # Pushed status over the Automation WebSocket API instead of polling.
    $result = Submit-WorkItemViaWebSocket $ssaToken $activityId $Alias $arguments -signature $signature
} else {
    $id = Submit-WorkItem $ssaToken $activityId $Alias $arguments -signature $signature
    $result = Wait-WorkItem $ssaToken $id
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
if ($result.status -ne "success") {
    if ($result.reportUrl) {
        Download-FromUrl $result.reportUrl "$OutDir\report.txt"
        Get-Content "$OutDir\report.txt"
    }
    throw "WorkItem ended with status $($result.status)."
}

# --- Finalize the upload, then hand back a time-limited link ----------------------------------------
Invoke-RestMethod -Method Post -Uri "$OSS_BASE/buckets/$bucketKey/objects/$encObj/signeds3upload" `
    -Headers @{ Authorization = "Bearer $appToken"; "Content-Type" = "application/json" } `
    -Body (@{ uploadKey = $up.uploadKey } | ConvertTo-Json) | Out-Null
$dl = Invoke-RestMethod -Uri "$OSS_BASE/buckets/$bucketKey/objects/$encObj/signeds3download?minutesExpiration=60" `
    -Headers @{ Authorization = "Bearer $appToken" }
$outPath = Join-Path $OutDir $OutputName
Download-FromUrl $dl.url $outPath
# DA always names the input input.dwg, so a "Drawing" field written by the plugin is misleading.
# Put the real file name into the local copy (the OSS copy is unchanged).
if ($outPath -like "*.json") {
    $json = Get-Content $outPath -Raw | ConvertFrom-Json
    if ($json.PSObject.Properties["Drawing"]) {
        $json.Drawing = $item.attributes.displayName
        $json | ConvertTo-Json -Depth 10 | Set-Content $outPath -Encoding utf8
    }
}
if ($PutBack) {
    if (-not $RemoteName) { $RemoteName = "$([IO.Path]::GetFileNameWithoutExtension($item.attributes.displayName))-$OutputName" }
    Write-Host "`n-- Putting '$RemoteName' back into the folder --"
    Publish-FileToAccFolder $ssaToken $projectId $folderUrn $outPath $RemoteName | Out-Null
}
Write-Host "`nSUCCESS. $OutputName saved to $OutDir" -ForegroundColor Green
# The link is a presigned URL, so it is a credential: print it only when asked, never by default.
if ($ShowLink) { Write-Host "Download link (expires in 60 minutes): $($dl.url)" }
