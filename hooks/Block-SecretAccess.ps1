# PreToolUse hook: stops Claude from reading, searching, or editing credential files, and from
# dumping environment variables. Reads the hook JSON from stdin. Exit 2 blocks the call and the
# stderr text goes back to Claude; exit 0 allows it.
#
# Best effort, not a sandbox: a determined, obfuscated shell command can still get around the text
# match. It protects against the ordinary case of the model opening .env or a .pem. Works on
# Windows PowerShell 5.1 and PowerShell 7. Fails closed: an internal error blocks the call.
$ErrorActionPreference = "Stop"

# .env and .env.local block; .env.example does not. "mykey.json" is the activity-signing key.
$patterns = @(
    '(?<![\w])\.env(?!\.example\b)(\.[\w-]+)?(?![\w])',
    '\.pem(?![\w])',
    '(?i)mykey\.json',
    '(?i)[\\/]\.aps([\\/]|$)',
    '(?i)\.aps[\\/]'
)
# Shell commands only: naming the secret variables, or dumping the whole environment.
$shellPatterns = @(
    '(?i)APS_CLIENT_SECRET',
    '(?i)APS_SSA_PRIVATE_KEY',
    '(?i)\bprintenv\b',
    '(?i)\bGet-ChildItem\s+(-Path\s+)?env:',
    '(?i)\b(gci|ls|dir)\s+(-Path\s+)?env:',
    '(?i)\bGet-Item\s+(-Path\s+)?env:',
    '(?i)(^|[;&|]\s*)env(\s*$|\s*[|;&])',
    '(?i)\[Environment\]::GetEnvironmentVariables'
)

try {
    $raw = [Console]::In.ReadToEnd()
    $in = $raw | ConvertFrom-Json
    $ti = $in.tool_input
    $targets = @()
    foreach ($name in "file_path", "path", "glob", "notebook_path") {
        if ($ti -and $ti.PSObject.Properties[$name] -and $ti.$name) { $targets += [string]$ti.$name }
    }
    $isShell = $in.tool_name -in @("Bash", "PowerShell")
    if ($isShell -and $ti.command) { $targets += [string]$ti.command }

    foreach ($t in $targets) {
        foreach ($p in $patterns) {
            if ($t -match $p) {
                [Console]::Error.WriteLine("Blocked by aps-da-acad-c3d: this call touches a credential file ('.env', '.pem', 'mykey.json', or the ~/.aps folder). Ask the user to run the command themselves and share only non-secret output.")
                exit 2
            }
        }
    }
    if ($isShell -and $ti.command) {
        foreach ($p in $shellPatterns) {
            if ([string]$ti.command -match $p) {
                [Console]::Error.WriteLine("Blocked by aps-da-acad-c3d: this command names an APS secret variable or dumps the environment. Ask the user to run it in their own shell.")
                exit 2
            }
        }
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("Blocked by aps-da-acad-c3d: the secret-access hook failed ($($_.Exception.Message)), so the call was refused.")
    exit 2
}
