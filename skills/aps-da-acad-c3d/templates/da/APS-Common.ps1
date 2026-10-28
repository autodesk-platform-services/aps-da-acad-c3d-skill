# APS-Common.ps1 - Shared helpers for APS Design Automation scripts
# Dot-source this file: . .\APS-Common.ps1
# Fully generic across engines/bundles — no per-migration edits needed.

Add-Type -AssemblyName System.Net.Http

$DA_BASE  = "https://developer.api.autodesk.com/da/us-east/v3"
$OSS_BASE = "https://developer.api.autodesk.com/oss/v2"
$AUTH_URL = "https://developer.api.autodesk.com/authentication/v2/token"

# Load .env (copied from .env.example, gitignored) into the process environment,
# if present, before anything else reads $env:APS_*. Real credentials never pass
# through Claude — the developer fills in .env themselves on their own machine.
function Import-DotEnv {
    param([string] $Path = "")
    # Lookup order: APS_ENV_PATH, then the nearest .env in this folder or any parent folder, so one
    # shared file in a common parent folder serves every project underneath it.
    if (-not $Path) { $Path = $env:APS_ENV_PATH }
    if (-not $Path) {
        $dir = $PSScriptRoot
        while ($dir) {
            if (Test-Path (Join-Path $dir ".env")) { $Path = Join-Path $dir ".env"; break }
            $dir = Split-Path $dir -Parent
        }
    }
    if (-not $Path -or -not (Test-Path $Path)) { return }
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { return }
        $parts = $line.Split("=", 2)
        if ($parts.Count -eq 2 -and $parts[1].Trim() -ne "") {
            [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim(), "Process")
        }
    }
}
Import-DotEnv

# Auth

function Get-APSToken {
    $id     = if ($env:APS_CLIENT_ID)     { $env:APS_CLIENT_ID }     else { Read-Host "APS Client ID" }
    # Masked prompt so the secret is not echoed to the screen or scrollback.
    $secret = if ($env:APS_CLIENT_SECRET) { $env:APS_CLIENT_SECRET } else {
        [System.Net.NetworkCredential]::new("", (Read-Host "APS Client Secret" -AsSecureString)).Password
    }
    $env:APS_CLIENT_ID     = $id
    $env:APS_CLIENT_SECRET = $secret

    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${id}:${secret}"))
    $r = Invoke-RestMethod -Uri $AUTH_URL -Method POST `
        -Headers @{ Authorization = "Basic $b64" } `
        -ContentType "application/x-www-form-urlencoded" `
        -Body "grant_type=client_credentials&scope=code%3Aall%20data%3Aread%20data%3Awrite%20bucket%3Acreate%20bucket%3Aread%20bucket%3Aupdate"
    return $r.access_token
}

function Get-DANickname($token) {
    $r = Invoke-RestMethod -Uri "$DA_BASE/forgeapps/me" -Method GET `
        -Headers @{ Authorization = "Bearer $token" }
    # Observed response shape is a bare JSON string ("<value>"), not { "id": "<value>" } as
    # the APS docs/earlier assumption suggested — Invoke-RestMethod then deserializes it to
    # a plain .NET string with no .id property. Every caller reading $result.id on that gets
    # $null silently (no error), which is the actual root cause of nicknames resolving empty.
    # Normalize here so every caller gets a consistent bare string either way.
    if ($r -is [string]) { return $r }
    return $r.id
}

function Set-DANickname($token, $nickname) {
    $body = @{ nickname = $nickname } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri "$DA_BASE/forgeapps/me" -Method PATCH `
            -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
            -Body $body | Out-Null
        Write-Host "  Nickname set to '$nickname'" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  Nickname PATCH failed: $_" -ForegroundColor Yellow
        return $false
    }
}

# APS lets you set a forgeapps nickname exactly once — PATCHing it again once the app
# already owns bundles/activities fails with "already has resources", and everything
# downstream (bundle/activity/workitem qualification) must use whatever nickname is
# ACTUALLY registered, not whatever was typed at the prompt. Always call this instead
# of Set-DANickname directly; it only PATCHes when no nickname exists yet, and always
# returns the nickname callers should actually use.
function Resolve-DANickname($token, $requestedNickname) {
    $current = Get-DANickname $token
    # Get-DANickname always returns a bare string now — but when no custom nickname has
    # ever been registered, that string defaults to your raw APS_CLIENT_ID, not blank/null.
    # Comparing against $env:APS_CLIENT_ID (not just truthiness) is the only way to tell
    # "has a real nickname" apart from "still on the default identity".
    $hasRealNickname = $current -and ($current -ne $env:APS_CLIENT_ID)
    if ($hasRealNickname) {
        Write-Host "  Existing nickname: '$current'" -ForegroundColor Cyan
        if ($current -ne $requestedNickname) {
            Write-Host "  (requested '$requestedNickname' ignored — already registered)" -ForegroundColor Yellow
        }
        return $current
    }
    if (-not $requestedNickname) {
        throw "No forgeapps nickname is registered yet, and none was provided. Pass -Owner <nickname>."
    }
    $patched = Set-DANickname $token $requestedNickname
    if ($patched) {
        return $requestedNickname
    }
    # PATCH failed (e.g. "already has resources") — $current (fetched above, before the
    # PATCH attempt) is still accurate, since nothing changed. No need to re-GET: this is
    # the nickname/identity every downstream bundle/activity/workitem reference must use.
    Write-Host "  Nickname did not actually change — using registered identity '$current' instead of requested '$requestedNickname'." -ForegroundColor Yellow
    return $current
}

# DELETE /forgeapps/me — wipes EVERY bundle, activity, and the nickname itself for this
# client. Irreversible. Only call this from a script the user runs deliberately (e.g.
# Reset-APSApp.ps1), never as part of the normal deploy/test flow — it is the "start over
# from a clean slate" escape hatch when resource state has gotten confused across runs,
# not a routine step.
function Remove-DAAllResources($token) {
    Invoke-RestMethod -Uri "$DA_BASE/forgeapps/me" -Method DELETE `
        -Headers @{ Authorization = "Bearer $token" } | Out-Null
}

# DA helpers

function Invoke-DA($token, $method, $path, $body = $null) {
    $params = @{
        Uri     = "$DA_BASE/$path"
        Method  = $method
        Headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
    }
    if ($body) { $params.Body = ($body | ConvertTo-Json -Depth 10) }
    try   { return Invoke-RestMethod @params }
    catch { throw "DA $method $path -> $($_.Exception.Response.StatusCode): $($_.ErrorDetails.Message)" }
}

# GET appbundles/activities responses are paginated — { data: [...], paginationToken: "..." }.
# A single Invoke-DA call only returns one page (observed: ~20 items), silently truncating
# the real list. Follow paginationToken until it's absent to get everything.
function Get-DAAllPages($token, $path) {
    $all = @()
    $page = $null
    do {
        $p = if ($page) { "$path`?page=$page" } else { $path }
        $r = Invoke-DA $token GET $p
        $all += $r.data
        $page = $r.paginationToken
    } while ($page)
    return $all
}

# AppBundle

function Zip-Bundle {
    param([string]$BundleDir, [string]$ZipPath)
    if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
    # Archive the bundle folder itself (not its contents) so the zip expands to BundleName.bundle/
    Compress-Archive -Path $BundleDir -DestinationPath $ZipPath
    Write-Host "  Zipped: $ZipPath ($([math]::Round((Get-Item $ZipPath).Length/1KB)) KB)" -ForegroundColor Gray
}

function Register-AppBundle($token, $id, $engine, $description) {
    $body     = @{ id = $id; engine = $engine; description = $description }
    $bodyNoId = @{           engine = $engine; description = $description }
    try {
        $r = Invoke-DA $token POST "appbundles" $body
        Write-Host "  Created bundle '$id' (v$($r.version))" -ForegroundColor Green
        return $r
    } catch {
        if ($_ -match "409|Conflict|already exists") {
            $r = Invoke-DA $token POST "appbundles/$id/versions" $bodyNoId
            Write-Host "  Updated bundle '$id' (v$($r.version))" -ForegroundColor Yellow
            return $r
        }
        throw
    }
}

function Upload-BundleZip($uploadParams, [string]$zipPath) {
    # PowerShell's $PWD and .NET's Environment.CurrentDirectory can diverge (cd doesn't move
    # the latter) - raw [System.IO.FileStream] below resolves relative paths against .NET's
    # CWD, not the caller's actual working directory. Resolve to absolute first.
    $zipPath = (Resolve-Path $zipPath).Path
    $endpointUrl = $uploadParams.endpointURL
    $formData    = @{}
    $uploadParams.formData.psobject.properties | ForEach-Object { $formData[$_.Name] = $_.Value }

    $multipart = [System.Net.Http.MultipartFormDataContent]::new()
    foreach ($kv in $formData.GetEnumerator()) {
        $sc = [System.Net.Http.StringContent]::new($kv.Value)
        $sc.Headers.ContentDisposition = [System.Net.Http.Headers.ContentDispositionHeaderValue]::new("form-data")
        $sc.Headers.ContentDisposition.Name = $kv.Name
        $multipart.Add($sc)
    }
    $fs = [System.IO.FileStream]::new($zipPath, [System.IO.FileMode]::Open)
    $fc = [System.Net.Http.StreamContent]::new($fs)
    $fc.Headers.ContentDisposition = [System.Net.Http.Headers.ContentDispositionHeaderValue]::new("form-data")
    $fc.Headers.ContentDisposition.Name     = "file"
    $fc.Headers.ContentDisposition.FileName = [System.IO.Path]::GetFileName($zipPath)
    $fc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/octet-stream")
    $multipart.Add($fc)

    $client   = [System.Net.Http.HttpClient]::new()
    $response = $client.PostAsync($endpointUrl, $multipart).Result
    $fs.Close()
    if (-not $response.IsSuccessStatusCode) {
        $body = $response.Content.ReadAsStringAsync().Result
        throw "Bundle upload failed: $($response.StatusCode) - $body"
    }
    Write-Host "  Uploaded bundle to AWS" -ForegroundColor Green
}

function Set-BundleAlias($token, $bundleId, $alias, $version) {
    $body = @{ id = $alias; version = $version }
    try {
        Invoke-DA $token POST "appbundles/$bundleId/aliases" $body | Out-Null
        Write-Host "  Alias '$alias' -> v$version" -ForegroundColor Green
    } catch {
        if ($_ -match "409|Conflict|already exists") {
            Invoke-DA $token PATCH "appbundles/$bundleId/aliases/$alias" @{ version = $version } | Out-Null
            Write-Host "  Alias '$alias' updated -> v$version" -ForegroundColor Yellow
        } else { throw }
    }
}

function Deploy-Bundle($token, $id, $engine, $description, $bundleDir, $zipPath) {
    Write-Host "`n-- $id --" -ForegroundColor Cyan
    Write-Host "  [1/4] Zipping..."
    Zip-Bundle $bundleDir $zipPath
    Write-Host "  [2/4] Registering with DA..."
    $r = Register-AppBundle $token $id $engine $description
    Write-Host "  [3/4] Uploading zip to AWS..."
    Upload-BundleZip $r.uploadParameters $zipPath
    Write-Host "  [4/4] Setting alias 'dev'..."
    Set-BundleAlias $token $id "dev" $r.version
}

# Activity

function Deploy-Activity($token, $activityDef) {
    $id = $activityDef.id
    $defNoId = @{}
    $activityDef.GetEnumerator() | Where-Object { $_.Key -ne "id" } | ForEach-Object { $defNoId[$_.Key] = $_.Value }
    try {
        $r = Invoke-DA $token POST "activities" $activityDef
        Write-Host "  Created activity '$id' (v$($r.version))" -ForegroundColor Green
        return $r
    } catch {
        if ($_ -match "409|Conflict|already exists") {
            $r = Invoke-DA $token POST "activities/$id/versions" $defNoId
            Write-Host "  Updated activity '$id' (v$($r.version))" -ForegroundColor Yellow
            return $r
        }
        throw
    }
}

function Set-ActivityAlias($token, $activityId, $alias, $version) {
    $body = @{ id = $alias; version = $version }
    try {
        Invoke-DA $token POST "activities/$activityId/aliases" $body | Out-Null
        Write-Host "  Alias '$alias' -> v$version" -ForegroundColor Green
    } catch {
        if ($_ -match "409|Conflict|already exists") {
            Invoke-DA $token PATCH "activities/$activityId/aliases/$alias" @{ version = $version } | Out-Null
            Write-Host "  Alias '$alias' updated -> v$version" -ForegroundColor Yellow
        } else { throw }
    }
}

# OSS

function Ensure-OSSBucket($token, $bucketKey) {
    try {
        Invoke-RestMethod -Uri "$OSS_BASE/buckets/$bucketKey/details" -Method GET `
            -Headers @{ Authorization = "Bearer $token" } | Out-Null
        Write-Host "  Bucket '$bucketKey' exists" -ForegroundColor Gray
    } catch {
        $body = @{ bucketKey = $bucketKey; policyKey = "persistent" } | ConvertTo-Json
        Invoke-RestMethod -Uri "$OSS_BASE/buckets" -Method POST `
            -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
            -Body $body | Out-Null
        Write-Host "  Bucket '$bucketKey' created" -ForegroundColor Green
    }
}

function Upload-ToOSS($token, $bucketKey, $objectKey, $filePath) {
    # Same PowerShell-$PWD-vs-.NET-CWD divergence as Upload-BundleZip - resolve before
    # the raw [System.IO.FileStream] call below.
    $filePath   = (Resolve-Path $filePath).Path
    $fileSize   = (Get-Item $filePath).Length
    $encodedKey = [Uri]::EscapeDataString($objectKey)

    $step1 = Invoke-RestMethod `
        -Uri "$OSS_BASE/buckets/$bucketKey/objects/$encodedKey/signeds3upload?minutesExpiration=60&useAcceleration=true&parts=1" `
        -Method GET `
        -Headers @{ Authorization = "Bearer $token" }

    $s3Url     = $step1.urls[0]
    $uploadKey = $step1.uploadKey

    $fs = [System.IO.FileStream]::new($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
    try {
        $client  = [System.Net.Http.HttpClient]::new()
        $content = [System.Net.Http.StreamContent]::new($fs)
        $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/octet-stream")
        $resp = $client.PutAsync($s3Url, $content).Result
        if (-not $resp.IsSuccessStatusCode) {
            $body = $resp.Content.ReadAsStringAsync().Result
            throw "S3 PUT failed: $($resp.StatusCode) - $body"
        }
    } finally {
        $fs.Close()
    }

    $r = Invoke-RestMethod `
        -Uri "$OSS_BASE/buckets/$bucketKey/objects/$encodedKey/signeds3upload" `
        -Method POST `
        -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
        -Body (@{ uploadKey = $uploadKey } | ConvertTo-Json)

    $sizeDisplay = if ($fileSize -lt 1KB) { "$fileSize B" } else { "$([math]::Round($fileSize/1KB, 1)) KB" }
    Write-Host "  Uploaded '$objectKey' ($sizeDisplay)" -ForegroundColor Green
    return $r.objectId
}

function Get-OSSSignedUrl($token, $bucketKey, $objectKey, [ValidateSet("read","write")]$access) {
    $encodedKey = [Uri]::EscapeDataString($objectKey)
    $r = Invoke-RestMethod `
        -Uri "$OSS_BASE/buckets/$bucketKey/objects/$encodedKey/signed?access=$access&minutesExpiration=60" `
        -Method POST `
        -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
        -Body "{}"
    return $r.signedUrl
}

function Download-FromUrl($url, $destPath) {
    Invoke-WebRequest -Uri $url -OutFile $destPath -UseBasicParsing
    $downloadedSize = (Get-Item $destPath).Length
    $sizeDisplay = if ($downloadedSize -lt 1KB) { "$downloadedSize B" } else { "$([math]::Round($downloadedSize/1KB, 1)) KB" }
    Write-Host "  Downloaded -> $destPath ($sizeDisplay)" -ForegroundColor Green
}

# WorkItem

# limitProcessingTimeSec: per-WorkItem cap, includes download and upload time. 3600 is the
# AutoCAD engine maximum. This is separate from the ~60s no-output heartbeat rule: a high
# limit does not stop a silent command from being killed (see references/da-guardrails.md).
# Retry-only options, both off by default (see "Troubleshooting a failed WorkItem"):
#   heartbeatTimeoutInMin: 1-10, sent as the adskHeartbeatTimeoutInMin argument. 0 omits it and
#                          leaves DA's default in force. Use after a timeout or no-output failure.
#   uploadJobFolder:       sends adskDebug.uploadJobFolder. Use after a crash in plugin code.
function Submit-WorkItem($token, $activityId, $alias, $arguments, [int]$limitProcessingTimeSec = 3600,
                         [ValidateRange(0, 10)][int]$heartbeatTimeoutInMin = 0,
                         [switch]$uploadJobFolder, [string]$signature = "") {
    # Sent as strings; see "Argument forms" in da-guardrails.md if DA rejects that form.
    if ($heartbeatTimeoutInMin -gt 0) { $arguments["adskHeartbeatTimeoutInMin"] = "$heartbeatTimeoutInMin" }
    if ($uploadJobFolder) { $arguments["adskDebug"] = '{"uploadJobFolder":true}' }
    $body = @{
        activityId             = "$activityId+$alias"
        arguments              = $arguments
        LimitProcessingTimeSec = $limitProcessingTimeSec
    }
    # $signature comes from Get-ActivitySignature. Required when $token is an SSA (3-legged) token.
    if ($signature) { $body["signatures"] = @{ activityId = $signature } }
    $r = Invoke-DA $token POST "workitems" $body
    Write-Host "  WorkItem submitted: $($r.id)" -ForegroundColor Cyan
    return $r.id
}

# Default outlasts Submit-WorkItem's 3600s processing limit so the poll does not give up first.
function Wait-WorkItem($token, $workItemId, [int]$timeoutSec = 3900) {
    $elapsed = 0
    do {
        Start-Sleep -Seconds 5
        $elapsed += 5
        $r = Invoke-DA $token GET "workitems/$workItemId"
        # approximateQueuePosition is a Beta field: 1-based, can be null, absent once processing starts.
        $queuePos = if ($r.approximateQueuePosition) { " (queue position ~$($r.approximateQueuePosition))" } else { "" }
        Write-Host "  [$elapsed s] Status: $($r.status)$queuePos" -ForegroundColor Gray
    } while ($r.status -in @("pending","inprogress") -and $elapsed -lt $timeoutSec)

    if ($r.status -eq "success") {
        Write-Host "  WorkItem SUCCEEDED" -ForegroundColor Green
    } else {
        Write-Host "  WorkItem FAILED: $($r.status)" -ForegroundColor Red
        # The report URL is presigned (a credential), so it is not printed; callers download the report.
        if ($r.reportUrl) { Write-Host "  A WorkItem report is available (downloaded by the caller)." -ForegroundColor Yellow }
    }

    # DA's own stats breakdown — queue/download/processing/upload phases, not just our poll
    # interval. Useful for understanding where time (and DA cloud-credit cost) actually went,
    # instead of hand-timing "start of script" to "file appeared."
    if ($r.stats) {
        $s = $r.stats
        try {
            $queued  = [datetime]$s.timeQueued
            $dlStart = [datetime]$s.timeDownloadStarted
            $ixStart = [datetime]$s.timeInstructionsStarted
            $ixEnd   = [datetime]$s.timeInstructionsEnded
            $ulEnd   = [datetime]$s.timeUploadEnded
            $finished= [datetime]$s.timeFinished
            Write-Host "  Stats: queued->download $([math]::Round(($dlStart-$queued).TotalSeconds,1))s | download->processing $([math]::Round(($ixStart-$dlStart).TotalSeconds,1))s | processing $([math]::Round(($ixEnd-$ixStart).TotalSeconds,1))s | upload $([math]::Round(($ulEnd-$ixEnd).TotalSeconds,1))s | total $([math]::Round(($finished-$queued).TotalSeconds,1))s" -ForegroundColor DarkGray
        } catch { }
        if ($s.bytesDownloaded -or $s.bytesUploaded) {
            Write-Host "  Data: downloaded $($s.bytesDownloaded) B, uploaded $($s.bytesUploaded) B" -ForegroundColor DarkGray
        }
    }
    return $r
}

# Builds a WorkItem argument that points at an OSS, ACC, or Forma object by URN, so no signed
# URL is needed. Both keys are URL-encoded here. $verb is "get" (input) or "put" (output); the
# token needs data:read or data:write respectively (3-legged for ACC/Forma buckets).
function New-OSSObjectArgument([string]$bucketKey, [string]$objectKey, [ValidateSet("get","put")][string]$verb, [string]$token) {
    $urn = "urn:adsk.objects:os.object:$([Uri]::EscapeDataString($bucketKey))/$([Uri]::EscapeDataString($objectKey))"
    return @{ url = $urn; verb = $verb; headers = @{ Authorization = "Bearer $token" } }
}

# Fills APS_SSA_SERVICE_ACCOUNT_ID / APS_SSA_KEY_ID / APS_SSA_PRIVATE_KEY_PATH in this process only, so
# .env needs just APS_CLIENT_ID, APS_CLIENT_SECRET, SSA_FIRST_NAME and SSA_LAST_NAME. The SSA email is
# "<first>-<last>@<client id>.adskserviceaccount.com". Order: values already set and their PEM exists ->
# reuse; else find the account by email (create it if there is none), then use a key whose PEM is in
# ~/.aps (<kid>.pem, matched by file name only), else create a key and save its PEM there. Nothing is
# written to .env, and no secret is printed. A new SSA still needs the human ACC steps (Custom Integration
# for the client id, project membership for the SSA email).
function Resolve-SsaConfig {
    if ($env:APS_SSA_SERVICE_ACCOUNT_ID -and $env:APS_SSA_KEY_ID -and $env:APS_SSA_PRIVATE_KEY_PATH -and
        (Test-Path $env:APS_SSA_PRIVATE_KEY_PATH)) { return }
    foreach ($n in "SSA_FIRST_NAME","SSA_LAST_NAME") {
        if (-not [Environment]::GetEnvironmentVariable($n)) { throw "Missing $n. Set it in da/.env (the SSA email is <first>-<last>@...)." }
    }
    $name = "$($env:SSA_FIRST_NAME)-$($env:SSA_LAST_NAME)"
    $authBase = "https://developer.api.autodesk.com/authentication/v2"
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($env:APS_CLIENT_ID):$($env:APS_CLIENT_SECRET)"))
    $t = Invoke-RestMethod -Method Post -Uri "$authBase/token" -Headers @{ Authorization = "Basic $basic" } `
        -ContentType "application/x-www-form-urlencoded" `
        -Body @{ grant_type = "client_credentials"; scope = "application:service_account:read application:service_account:write application:service_account_key:read application:service_account_key:write" }
    $h = @{ Authorization = "Bearer $($t.access_token)" }

    $account = @((Invoke-RestMethod -Uri "$authBase/service-accounts" -Headers $h).serviceAccounts) |
        Where-Object { $_.email -like "$name@*" } | Select-Object -First 1
    if ($account) {
        Write-Host "  SSA: reusing $($account.email)" -ForegroundColor Gray
    } else {
        $account = Invoke-RestMethod -Method Post -Uri "$authBase/service-accounts" -Headers $h -ContentType "application/json" `
            -Body (@{ name = $name; firstName = $env:SSA_FIRST_NAME; lastName = $env:SSA_LAST_NAME } | ConvertTo-Json)
        Write-Host "  SSA: created $($account.email). A human must add it to the ACC project (Docs access) and register the client id under Custom Integrations." -ForegroundColor Yellow
    }

    $keyDir = Join-Path $HOME ".aps"
    $kid = $null; $pemPath = $null
    $existing = @()
    try { $existing = @((Invoke-RestMethod -Uri "$authBase/service-accounts/$($account.serviceAccountId)/keys" -Headers $h).keys | ForEach-Object { $_.kid }) } catch { }
    foreach ($k in $existing) {
        $p = Join-Path $keyDir "$k.pem"
        if (Test-Path $p) { $kid = $k; $pemPath = $p; break }
    }
    if (-not $kid) {
        try { $key = Invoke-RestMethod -Method Post -Uri "$authBase/service-accounts/$($account.serviceAccountId)/keys" -Headers $h }
        catch { throw "Could not create a key for $($account.email): $($_.ErrorDetails.Message). The account may be at its key limit; delete an unused key, or put the existing <kid>.pem files in $keyDir." }
        if (-not $key.privateKey -or -not $key.kid) { throw "Key response had no kid or privateKey." }
        New-Item -ItemType Directory -Force $keyDir | Out-Null
        $pemPath = Join-Path $keyDir "$($key.kid).pem"
        [IO.File]::WriteAllText($pemPath, $key.privateKey, (New-Object Text.UTF8Encoding($false)))
        icacls $pemPath /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not restrict permissions on $pemPath." }
        $kid = $key.kid
        Write-Host "  SSA: new key saved under $keyDir (current user only). Keep that folder: it holds the only copy of the key, and an account can have only a limited number of keys." -ForegroundColor Gray
    }
    $env:APS_SSA_SERVICE_ACCOUNT_ID = $account.serviceAccountId
    $env:APS_SSA_KEY_ID = $kid
    $env:APS_SSA_PRIVATE_KEY_PATH = $pemPath
}

# Secure Service Account (SSA) token via a signed JWT bearer assertion, so ACC/Forma files can be
# read without a browser sign-in.
# Needs PowerShell 7+ (RSA.ImportFromPem). Reads from the environment (loaded from da/.env):
#   APS_CLIENT_ID, APS_CLIENT_SECRET, APS_SSA_SERVICE_ACCOUNT_ID, APS_SSA_KEY_ID,
#   APS_SSA_PRIVATE_KEY_PATH (a PEM file outside the repo).
# Scope goes in the assertion as an array AND in the form body. The token is
# returned, never printed.
function Get-SsaToken([string]$scope = "data:read data:write") {
    foreach ($name in "APS_CLIENT_ID","APS_CLIENT_SECRET") {
        if (-not [Environment]::GetEnvironmentVariable($name)) { throw "Missing $name. Set it in da/.env." }
    }
    Resolve-SsaConfig
    $keyPath = $env:APS_SSA_PRIVATE_KEY_PATH
    if (-not (Test-Path $keyPath)) { throw "Private key file not found: $keyPath" }
    $aud = "https://developer.api.autodesk.com/authentication/v2/token"

    function ConvertTo-Base64Url([byte[]]$bytes) { [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_') }
    $header  = @{ alg = "RS256"; typ = "JWT"; kid = $env:APS_SSA_KEY_ID } | ConvertTo-Json -Compress
    $payload = @{
        iss   = $env:APS_CLIENT_ID
        sub   = $env:APS_SSA_SERVICE_ACCOUNT_ID
        aud   = $aud
        exp   = [DateTimeOffset]::UtcNow.AddSeconds(300).ToUnixTimeSeconds()
        scope = @($scope -split ' ')
    } | ConvertTo-Json -Compress
    $unsigned = "$(ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($header))).$(ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($payload)))"

    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem((Get-Content $keyPath -Raw))
        $sig = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($unsigned),
                             [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                             [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally { $rsa.Dispose() }
    $jwt = "$unsigned.$(ConvertTo-Base64Url $sig)"

    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($env:APS_CLIENT_ID):$($env:APS_CLIENT_SECRET)"))
    $r = Invoke-RestMethod -Method Post -Uri $aud -Headers @{ Authorization = "Basic $basic" } `
        -ContentType "application/x-www-form-urlencoded" `
        -Body @{ grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer"; assertion = $jwt; scope = $scope }
    if (-not $r.access_token) { throw "SSA token response had no access_token." }
    return $r.access_token
}

# --- Signed activities (needed to submit a WorkItem with an SSA / 3-legged token) ---------------
# Logic matches the official aps-designautomation-signer:
# RSA SHA-256 over the UTF-16LE bytes of the full activity id, base64, no line breaks. Only
# the signed id must carry your own nickname (clone an Autodesk activity under it if needed). Key files use the .NET RSAParameters JSON shape.

# One-time: generates the key pair, registers nickname + public key (PATCH forgeapps/me), and only
# then writes the files, so a failed PATCH leaves nothing behind. The private key file must stay out
# of git. The nickname can be set only once per app.
function Register-DaSigningKey($token, [string]$nickname, [string]$privateKeyPath = "$PSScriptRoot\mykey.json",
                               [string]$publicKeyPath = "$PSScriptRoot\mypublickey.json") {
    if (Test-Path $privateKeyPath) { throw "$privateKeyPath already exists, refusing to overwrite it." }
    function ConvertTo-B64([byte[]]$b) { [Convert]::ToBase64String($b) }
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    try {
        $p = $rsa.ExportParameters($true)
        $public  = [ordered]@{ Exponent = (ConvertTo-B64 $p.Exponent); Modulus = (ConvertTo-B64 $p.Modulus) }
        $private = [ordered]@{ D = (ConvertTo-B64 $p.D); DP = (ConvertTo-B64 $p.DP); DQ = (ConvertTo-B64 $p.DQ)
                               Exponent = $public.Exponent; InverseQ = (ConvertTo-B64 $p.InverseQ)
                               Modulus = $public.Modulus; P = (ConvertTo-B64 $p.P); Q = (ConvertTo-B64 $p.Q) }
    } finally { $rsa.Dispose() }
    Invoke-DA $token PATCH "forgeapps/me" @{ nickname = $nickname; publicKey = $public } | Out-Null
    $private | ConvertTo-Json | Set-Content -Path $privateKeyPath -Encoding utf8
    $public  | ConvertTo-Json | Set-Content -Path $publicKeyPath -Encoding utf8
    Write-Host "  Saved $privateKeyPath (private, keep out of git) and $publicKeyPath" -ForegroundColor Yellow
}

# $activityId is the full id, "<nickname>.<activity>+<alias>". Returns the base64 signature.
function Get-ActivitySignature([string]$activityId, [string]$privateKeyPath = "$PSScriptRoot\mykey.json") {
    if (-not (Test-Path $privateKeyPath)) { throw "Signing key not found: $privateKeyPath. Run Register-DaSigningKey once." }
    $j = Get-Content $privateKeyPath -Raw | ConvertFrom-Json
    $p = New-Object System.Security.Cryptography.RSAParameters
    $p.D = [Convert]::FromBase64String($j.D);   $p.DP = [Convert]::FromBase64String($j.DP)
    $p.DQ = [Convert]::FromBase64String($j.DQ); $p.Exponent = [Convert]::FromBase64String($j.Exponent)
    $p.InverseQ = [Convert]::FromBase64String($j.InverseQ); $p.Modulus = [Convert]::FromBase64String($j.Modulus)
    $p.P = [Convert]::FromBase64String($j.P);   $p.Q = [Convert]::FromBase64String($j.Q)
    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportParameters($p)
        $sig = $rsa.SignData([Text.Encoding]::Unicode.GetBytes($activityId),
                             [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                             [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } finally { $rsa.Dispose() }
    return [Convert]::ToBase64String($sig)
}

# --- Put a local file into an ACC / Forma folder -----------------------------------------------------
# Creates the file as a new item, or as a new version when an item with that name already exists in
# the folder. $token is an SSA (user-context) token with data:read data:write data:create, and the SSA
# needs upload/edit permission on the folder (View and Download is not enough). Returns the item id.
# Steps: create a storage location, upload to it with a signed S3 URL, then register the item/version.
function Publish-FileToAccFolder($token, [string]$projectId, [string]$folderUrn, [string]$localPath, [string]$remoteName) {
    $dm = "https://developer.api.autodesk.com"
    $jsonApi = @{ Authorization = "Bearer $token"; "Content-Type" = "application/vnd.api+json"; Accept = "application/vnd.api+json" }
    function Invoke-Dm([string]$method, [string]$path, $body) {
        try { return Invoke-RestMethod -Method $method -Uri "$dm$path" -Headers $jsonApi -Body ($body | ConvertTo-Json -Depth 10) }
        catch { throw "$method $path -> $($_.Exception.Response.StatusCode.value__): $($_.ErrorDetails.Message). 403 means the service account lacks upload permission on the folder." }
    }
    $localPath = (Resolve-Path $localPath).Path

    # 1. Storage location in the folder
    $storage = Invoke-Dm POST "/data/v1/projects/$projectId/storage" @{
        jsonapi = @{ version = "1.0" }
        data = @{ type = "objects"; attributes = @{ name = $remoteName }
                  relationships = @{ target = @{ data = @{ type = "folders"; id = $folderUrn } } } } }
    $storageId = $storage.data.id                        # urn:adsk.objects:os.object:<bucket>/<object>
    if ($storageId -notmatch 'os\.object:([^/]+)/(.+)$') { throw "Unexpected storage id: $storageId" }
    $bucket = $Matches[1]; $object = $Matches[2]

    # 2. Upload with a signed S3 URL, then finalize
    $oss = "$dm/oss/v2/buckets/$bucket/objects/$([Uri]::EscapeDataString($object))/signeds3upload"
    $auth = @{ Authorization = "Bearer $token" }
    $up = Invoke-RestMethod -Uri "$oss`?parts=1&minutesExpiration=30" -Headers $auth
    $bytes = [IO.File]::ReadAllBytes($localPath)
    Invoke-RestMethod -Method Put -Uri $up.urls[0] -Body $bytes -ContentType "application/octet-stream" | Out-Null
    Invoke-RestMethod -Method Post -Uri $oss -Headers ($auth + @{ "Content-Type" = "application/json" }) `
        -Body (@{ uploadKey = $up.uploadKey } | ConvertTo-Json) | Out-Null

    # 3. New item, or new version of the existing item with this name
    $existing = @((Invoke-RestMethod -Uri "$dm/data/v1/projects/$projectId/folders/$([Uri]::EscapeDataString($folderUrn))/contents?filter[type]=items&filter[displayName]=$([Uri]::EscapeDataString($remoteName))" -Headers $auth).data)
    if ($existing.Count -gt 0) {
        $itemId = $existing[0].id
        Invoke-Dm POST "/data/v1/projects/$projectId/versions" @{
            jsonapi = @{ version = "1.0" }
            data = @{ type = "versions"
                      attributes = @{ name = $remoteName; extension = @{ type = "versions:autodesk.bim360:File"; version = "1.0" } }
                      relationships = @{ item = @{ data = @{ type = "items"; id = $itemId } }
                                         storage = @{ data = @{ type = "objects"; id = $storageId } } } } } | Out-Null
        Write-Host "  Added a new version of '$remoteName' in the folder." -ForegroundColor Green
    } else {
        $r = Invoke-Dm POST "/data/v1/projects/$projectId/items" @{
            jsonapi = @{ version = "1.0" }
            data = @{ type = "items"
                      attributes = @{ displayName = $remoteName; extension = @{ type = "items:autodesk.bim360:File"; version = "1.0" } }
                      relationships = @{ tip = @{ data = @{ type = "versions"; id = "1" } }
                                         parent = @{ data = @{ type = "folders"; id = $folderUrn } } } }
            included = @(@{ type = "versions"; id = "1"
                            attributes = @{ name = $remoteName; extension = @{ type = "versions:autodesk.bim360:File"; version = "1.0" } }
                            relationships = @{ storage = @{ data = @{ type = "objects"; id = $storageId } } } }) }
        $itemId = $r.data.id
        Write-Host "  Created '$remoteName' in the folder." -ForegroundColor Green
    }
    return $itemId
}

# --- Submit a WorkItem over the Automation WebSocket API (no polling, no callback URL needed) ---------
# Connects to the Automation WebSocket service, posts the WorkItem, and reads status messages until a
# terminal status. Returns an object shaped like the REST result: id, status, reportUrl, stats.
# The WorkItem must not carry onComplete/onProgress. $signature is the signed-activity signature
# (Get-ActivitySignature), needed when $token is an SSA or other 3-legged token. Whether the socket
# accepts the "signatures" field must be verified live; a rejection arrives as an "error" message.
function Submit-WorkItemViaWebSocket($token, $activityId, $alias, $arguments, [int]$limitProcessingTimeSec = 3600, [string]$signature = "") {
    $ws  = [System.Net.WebSockets.ClientWebSocket]::new()
    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($limitProcessingTimeSec + 300))
    try {
        $ws.ConnectAsync([Uri]"wss://websockets.forgedesignautomation.io", $cts.Token).GetAwaiter().GetResult()
        $workItem = @{ activityId = "$activityId+$alias"; arguments = $arguments; LimitProcessingTimeSec = $limitProcessingTimeSec }
        if ($signature) { $workItem["signatures"] = @{ activityId = $signature } }
        $payload = @{ action = "post-workitem"; data = $workItem; headers = @{ Authorization = "Bearer $token" } } |
            ConvertTo-Json -Depth 10 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()
        Write-Host "  WorkItem posted over WebSocket" -ForegroundColor Cyan

        $buffer = New-Object byte[] 8192
        $last = ""
        while ($true) {
            $ms = [System.IO.MemoryStream]::new()
            do {   # one message can span several frames
                $r = $ws.ReceiveAsync([ArraySegment[byte]]::new($buffer), $cts.Token).GetAwaiter().GetResult()
                if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    throw "WebSocket closed by the server before a final status ($($r.CloseStatusDescription))."
                }
                $ms.Write($buffer, 0, $r.Count)
            } until ($r.EndOfMessage)
            $msg = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
            if ($msg.action -eq "error") { throw "WebSocket error: $($msg.data | ConvertTo-Json -Compress -Depth 5)" }
            if ($msg.action -ne "status") { continue }
            $s = $msg.data
            if ($s.status -ne $last) { Write-Host "  Status: $($s.status)" -ForegroundColor Gray; $last = $s.status }
            if ($s.status -notin @("pending", "inprogress")) {
                if ($s.status -eq "success") { Write-Host "  WorkItem SUCCEEDED" -ForegroundColor Green }
                else { Write-Host "  WorkItem FAILED: $($s.status)" -ForegroundColor Red }
                return $s
            }
        }
    } finally {
        if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            try { $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() } catch { }
        }
        $ws.Dispose(); $cts.Dispose()
    }
}
