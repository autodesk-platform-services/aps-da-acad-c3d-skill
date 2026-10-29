#Requires -Version 7
<#
.SYNOPSIS
    Pair-mode helper: finds or creates the Secure Service Account (SSA), makes sure its key exists,
    and optionally checks that it can read a Forma folder.

.DESCRIPTION
    A thin wrapper. The real work is Resolve-SsaConfig in APS-Common.ps1, which every run script
    already calls, so running this is optional. It is useful to see the SSA email and to find out
    early whether the human admin steps are done.

    Needs APS_CLIENT_ID, APS_CLIENT_SECRET, SSA_FIRST_NAME and SSA_LAST_NAME in a .env file in this
    folder or any parent folder (or at APS_ENV_PATH). The SSA email is
    <first>-<last>@<client id>.adskserviceaccount.com. An existing account with that email is reused;
    its key is found by file name in ~/.aps, or a new key is created there. Nothing is written to .env.
    No token, key or secret is printed.

.PARAMETER Link
    Forma folder link. When given, the script runs Test-FormaAccess.ps1, which prints a
    ready-to-send admin message if the SSA cannot read the folder.

.PARAMETER Write
    Check for upload permission too (results will be put back into the folder).

.EXAMPLE
    .\Setup-Ssa.ps1 -Link "<Forma folder link>"
#>
param(
    [string] $FirstName,
    [string] $LastName,
    [string] $Link,
    [switch] $Write
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\APS-Common.ps1"   # loads .env from this folder or a parent

# Optional overrides for this run only; .env is not changed.
if ($FirstName) { $env:SSA_FIRST_NAME = $FirstName }
if ($LastName)  { $env:SSA_LAST_NAME  = $LastName }
foreach ($v in "APS_CLIENT_ID", "APS_CLIENT_SECRET") {
    if (-not [Environment]::GetEnvironmentVariable($v)) { throw "Missing $v. Add it to your .env file (see .env.example)." }
}

Resolve-SsaConfig
Write-Host "SSA email: $($env:SSA_FIRST_NAME)-$($env:SSA_LAST_NAME)@$($env:APS_CLIENT_ID).adskserviceaccount.com"

if ($Link) {
    & "$PSScriptRoot\Test-FormaAccess.ps1" -Link $Link -Write:$Write
    exit $LASTEXITCODE
}
Write-Host "Pass -Link <Forma folder link> to check that this account can read (and with -Write, upload to) the folder." -ForegroundColor Yellow
