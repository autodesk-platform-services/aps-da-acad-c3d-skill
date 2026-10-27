#Requires -Version 7
<#
.SYNOPSIS
  DESTRUCTIVE. Deletes every AppBundle, Activity, and the nickname itself
  registered under your APS_CLIENT_ID (DELETE /forgeapps/me). Irreversible.

  Use this only when Design Automation resource state has gotten confused
  across runs (mismatched owner prefixes, a corrupted nickname, etc.) and you
  want to start over from a clean slate. Not part of the normal deploy/test
  flow — Deploy-And-Test-DA.ps1 never calls this.

.EXAMPLE
  ./Reset-APSApp.ps1 -Confirm
#>
param(
    [switch] $Confirm,
    [int]    $SettleSeconds = 100  # server-side deletion propagation is not instant
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\APS-Common.ps1"

if (-not $Confirm) {
    Write-Error "This deletes ALL AppBundles/Activities/nickname for your APS_CLIENT_ID. Re-run with -Confirm to proceed."
    exit 1
}

$token  = Get-APSToken
$before = Get-DANickname $token
# GET appbundles/activities return the PUBLIC catalog (every publicly-published activity
# across APS, including other teams'/products' official entries), not just this identity's
# own resources — and only one page at a time. Fetch every page, then filter to only the
# entries actually prefixed with this identity, so the count below reflects what DELETE
# /forgeapps/me will actually remove, not an unrelated public-catalog page-1 snapshot.
$prefix     = "$before."
$bundles    = @(try { Get-DAAllPages $token "appbundles"  } catch { @() }) | Where-Object { $_.id -like "$prefix*" }
$activities = @(try { Get-DAAllPages $token "activities" } catch { @() }) | Where-Object { $_.id -like "$prefix*" }

Write-Host ""
Write-Host "############################################################" -ForegroundColor Red
Write-Host "#  WARNING: DESTRUCTIVE, IRREVERSIBLE OPERATION             #" -ForegroundColor Red
Write-Host "#  DELETE /forgeapps/me wipes ALL of the following:         #" -ForegroundColor Red
Write-Host "############################################################" -ForegroundColor Red
Write-Host "  Identity        : $before" -ForegroundColor Yellow
Write-Host "  AppBundles      : $($bundles.Count)"  -ForegroundColor Yellow
Write-Host "  Activities      : $($activities.Count)" -ForegroundColor Yellow
Write-Host "  Nickname itself : will be un-registered" -ForegroundColor Yellow
Write-Host "  This CANNOT be undone. Every version/alias of every bundle" -ForegroundColor Red
Write-Host "  and activity above is gone, not just the latest version."   -ForegroundColor Red
Write-Host "############################################################" -ForegroundColor Red
Write-Host ""

$typed = Read-Host "Type DELETE (all caps) to proceed, anything else to abort"
if ($typed -cne "DELETE") {
    Write-Host "Aborted — nothing was deleted." -ForegroundColor Cyan
    exit 0
}

Remove-DAAllResources $token
Write-Host "Delete request accepted — waiting ${SettleSeconds}s for it to actually propagate" -ForegroundColor Yellow
Write-Host "server-side before anything else touches this identity (DA deletion is not" -ForegroundColor Yellow
Write-Host "instant; running Deploy-And-Test-DA.ps1 immediately after risks racing stale state)." -ForegroundColor Yellow

for ($elapsed = 0; $elapsed -lt $SettleSeconds; $elapsed += 10) {
    $remaining = $SettleSeconds - $elapsed
    Write-Host "  ${remaining}s remaining..." -ForegroundColor DarkGray
    Start-Sleep -Seconds ([Math]::Min(10, $remaining))
}

Write-Host "All Design Automation resources deleted for this client." -ForegroundColor Green
Write-Host "Next Deploy-And-Test-DA.ps1 run will register a fresh nickname from -Owner."
