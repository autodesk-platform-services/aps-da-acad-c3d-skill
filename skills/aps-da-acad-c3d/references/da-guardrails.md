# Design Automation guardrails

Read this when deploying to APS or when a WorkItem fails. Each item below was a real failure in live DA runs.

## Credentials

Never request, handle, or type `APS_CLIENT_ID` or `APS_CLIENT_SECRET` in conversation. The user copies `templates/da/.env.example` to `da/.env` (gitignored), fills it in from an APS app with Design Automation and Data Management enabled, and runs the scripts themselves. `APS-Common.ps1` loads `.env` automatically. You may help read the output of a run.

Copying a filled-in `.env` between the user's own projects is fine if they direct it and you never read or echo the values.

**What counts as a credential:** the client secret, the SSA private key (`*.pem`), the signing key (`mykey.json`), every access token, the SSA key id and service account id, and presigned URLs (they grant access until they expire).

**How to treat them once the user has set them up:**
- Do not open, grep, edit, or print `.env`, `*.pem`, `mykey.json`, or the `~\.aps` folder, and do not dump environment variables. The plugin's `hooks/Block-SecretAccess.ps1` enforces this for the Read, Grep, Edit, Write, Bash and PowerShell tools. If a call is blocked, do not look for another way to read the value. Ask the user to run the command and share only non-secret output.
- Do not put a credential value in code, a script argument, a committed file, a log line, or an eval fixture. Scripts read them from the environment.
- If the user pastes a secret or key into the chat anyway, do not repeat it, do not save it anywhere, and tell them to rotate it (new secret in the APS app, or a new SSA key) because it is now in the conversation history.
- Treat run logs and WorkItem reports as sensitive; they can contain presigned URLs. Ask the user to remove URLs and tokens before pasting them.
- Prefer non-secret identifiers when you need to refer to the setup, such as "the SSA configured in `.env`".

## Fully qualify every DA reference

`POST /workitems` needs `activityId` as `<nickname>.<activityId>+<alias>`. A bare id returns `Cannot parse id.` or `could not be found`. The `appbundles` array inside an Activity needs the same qualification. `APS-Common.ps1` builds these correctly.

## Nicknames are set once

- `GET /forgeapps/me` returns a **bare JSON string**, not an object, so `$result.id` is silently `$null`.
- When no nickname was ever registered, the value defaults to the raw `APS_CLIENT_ID`. Compare against it rather than testing for truthiness.
- Once the app owns any bundle or activity, PATCHing a nickname fails with `already has resources`. Use the existing nickname.
- `-Owner <real nickname>` is a manual override if resolution misbehaves.

## List endpoints are public and paged

`GET /appbundles` and `GET /activities` return the public catalog, one page at a time. Loop on `paginationToken` (`Get-DAAllPages`) and filter client-side by `"$Owner."` to find the user's own resources.

## Paths

.NET `FileStream` resolves relative paths against the process working directory, not PowerShell's `$PWD`. Resolve every user-supplied path with `(Resolve-Path ...).Path` before it reaches file I/O. The same applies to everything handed to `accoreconsole.exe`: the `/s` script, the `/i` drawing, and the `NETLOAD` target inside the script.

## Seed DWG without AutoCAD desktop

Only needed when the command reads entities that must already exist. A command that only creates geometry can run against any blank drawing, so run `accoreconsole` with no `/i`.

Otherwise add a dev-only `[CommandMethod]` (for example `MYSEED`) that builds the minimal entities through the Database API. Never list it in `PackageContents.xml`. Run `accoreconsole` with no `/i` and this script:

```
FILEDIA
0
SECURELOAD
0
NETLOAD
<absolute path>\<ProjectName>.dll
MYSEED
QSAVE
<absolute path>\seed.dwg
QUIT
Y
```

`FILEDIA 0` makes `QSAVE` ask for the filename on the command line instead of opening a dialog.

## Reset

`da/Reset-APSApp.ps1 -Confirm` runs `DELETE /forgeapps/me`, wiping every AppBundle, Activity, and nickname for that `APS_CLIENT_ID`. It prints counts, requires typing `DELETE`, and waits about 100 seconds because deletion is not instant. It is a last resort for confused state, never part of a normal run.

## Heartbeat: about 60 seconds of silence kills the job

A WorkItem that runs your bundle for more than about one minute without writing output fails. A single long call (opening a large file, `Corridor.Rebuild()`, a big LandXML import) produces no output on its own, so write your own.

- Use `Editor.WriteMessage`, not `Console.WriteLine`. In live Civil 3D runs, the `WriteMessage` lines appeared in the WorkItem report and every `Console.WriteLine` did not. The report captures AutoCAD's own text output, not raw stdout.
- Start a background writer before the long call and cancel it in `finally`:

```csharp
using var heartbeatCts = new CancellationTokenSource();
var heartbeatTask = Task.Run(async () =>
{
    while (!heartbeatCts.IsCancellationRequested)
    {
        await Task.Delay(TimeSpan.FromSeconds(10), heartbeatCts.Token).ContinueWith(_ => { });
        if (!heartbeatCts.IsCancellationRequested)
            ed.WriteMessage($"[{sw.Elapsed}] still working...\n");
    }
});
try { /* long operation */ }
finally { heartbeatCts.Cancel(); }
```

The 10-second interval gave a wide margin in a ~40 second LandXML import. Those runs were short, so treat a background-thread `WriteMessage` over many minutes as unproven until you have a long run.

Why it happens: if the plugin writes nothing to the console for more than about 60 seconds, the worker treats the instance as idle and shuts it down. Writing progress output is the real fix. The grace setting is the workaround when the output cannot be added (a single native call that blocks): it widens the idle wait from the default to anywhere in 1 to 10 minutes.

The window is configurable per WorkItem with `adskHeartbeatTimeoutInMin`, an integer from 1 to 10 minutes. It goes in the WorkItem's `arguments` object, not in the Activity. **Do not add it to a first submission.** It is a troubleshooting setting: add it when a WorkItem fails with a time limit or timeout error, then retry (see "Troubleshooting a failed WorkItem" below). The default idle window is about 1 minute. Raising it buys headroom for one long call, but it does not remove the need for output: pick the smallest value that fits, and keep the heartbeat writer. Example retry WorkItem body (the `url` values are placeholders):

```json
{
  "activityId": "AutoCAD.PlotToPDF+prod",
  "arguments": {
    "HostDwg": { "url": "https://example.com/test-data/SNX703A02.dwg", "verb": "get" },
    "Result": { "url": "https://example.com/result", "verb": "put" },
    "adskDebug": { "uploadJobFolder": true },
    "adskHeartbeatTimeoutInMin": 5
  },
  "LimitProcessingTimeSec": 600
}
```

**Argument forms.** `Submit-WorkItem` sends `adskHeartbeatTimeoutInMin` as a string (`"5"`) and `adskDebug` as the string `{"uploadJobFolder":true}`. If DA rejects that form, send an integer and a JSON object as in the example above.

`adskDebug.uploadJobFolder: true` uploads the entire working folder as an artifact for troubleshooting. Like the heartbeat setting, it is troubleshooting-only; do not include it by default. The 1 to 10 range for the heartbeat is enforced by APS. Casing matters: `adskHeartbeatTimeoutInMin` with a capital H, and `LimitProcessingTimeSec` with a capital L.

## WorkItem time limit: set `LimitProcessingTimeSec` to 3600

Put `"LimitProcessingTimeSec": 3600` at the top level of the WorkItem body, beside `activityId` and `arguments`. It is the per-WorkItem cap, it includes download and upload time, and 3600 is the documented AutoCAD maximum. Exceeding it ends the WorkItem as `failedLimitProcessingTime`. `Submit-WorkItem` in `templates/da/APS-Common.ps1` sends 3600 by default, and `Wait-WorkItem` polls for 3900 seconds so it does not give up first.

This does not replace the heartbeat. They are separate rules, and raising the limit does not stop a silent command from being killed at about 60 seconds.
## Queue visibility (Beta, added Aug 10 2026)

Two additions from the [Automation API changelog](https://aps.autodesk.com/en/docs/design-automation/v3/change_history/changelog_v3):

- `GET workitems/:id` returns `approximateQueuePosition` for pending WorkItems: 1-based, may be `null`, recalculated on every request, and absent once processing starts. `Wait-WorkItem` prints it when present.
- `GET health/:engine/stats` returns queue-time percentiles for one engine over the last 5 minutes. No helper exists yet.

Both are Beta, so formats may change. Tolerate unknown fields when parsing responses. Check the changelog page for entries after August 10 2026.

## Troubleshooting a failed WorkItem

First submissions carry `LimitProcessingTimeSec: 3600` and nothing else. Read the failure, then add one of these and retry. Offer the change to the user rather than silently adding it.

| Failure | Likely cause | Retry with |
|---------|--------------|------------|
| Time limit error (`failedLimitProcessingTime`) | The run, including download and upload, exceeded the cap | Check whether the command is genuinely slow. 3600 is already the AutoCAD maximum, so raising it is not an option; shrink the input or split the work |
| Timeout or no-output failure | A long call stayed silent past the heartbeat window | Add a heartbeat writer in the plugin (see above) and set `adskHeartbeatTimeoutInMin` in the WorkItem `arguments`, starting at the smallest value that fits (1 to 10) |
| Crash or unexpected failure inside plugin code (unhandled exception, `0xC0000005`, wrong output) | Bug or bad assumption in the plugin | Offer to add `"adskDebug": { "uploadJobFolder": true }` to the WorkItem `arguments` so the job folder can be inspected, then read the report and `ErrorReports` output |

The status string for a heartbeat timeout is not confirmed here, so match on the symptom (killed after silence) and read the WorkItem report before choosing.

`Submit-WorkItem` supports both retries: `-heartbeatTimeoutInMin <1-10>` and `-uploadJobFolder`. Neither is set by `Deploy-And-Test-DA.ps1` by default.

## Object URNs for OSS, Forma

Source: an APS Automation announcement the user pasted (not re-read from the docs). Check the live docs if a run disagrees.

A WorkItem argument `url` can be an object URN. No signed S3 URL is needed; prepare the objectId and an access token:

```json
{
  "activityId": "mynickname.myactivity+prod",
  "arguments": {
    "inputFile": {
      "url": "urn:adsk.objects:os.object:<bucket_key>/<object_key>",
      "verb": "get",
      "headers": { "Authorization": "Bearer <access_token>" }
    },
    "outputFile": {
      "url": "urn:adsk.objects:os.object:<bucket_key>/<object_key>",
      "verb": "put",
      "headers": { "Authorization": "Bearer <access_token>" }
    }
  },
  "LimitProcessingTimeSec": 3600
}
```

- `<bucket_key>` and `<object_key>` must be URL encoded.
- Works for all Automation engines, including AutoCAD.
- Automation builds the signed URL, refreshes an expired token, and uses multi-part upload for large files, so the one-hour signed-URL expiry no longer applies.
- Token scope: `data:read` for an input objectId, `data:write` for an output objectId. Buckets owned by Forma or BIM360 need a user-context token: 3-legged, or a Secure Service Account token when no one can sign in (see `forma-input.md`). A WorkItem submitted with that user-context token also needs a signature of the activity id (`signatures.activityId`) and an activity under your own nickname.

Finding the objectId:

| Source | Input | Output |
|--------|-------|--------|
| OSS | `GET Objects` returns it. | Build it directly from an existing bucket key plus a new object key; creating a storage first is optional. |
| Forma Data Management | `GET Version`, then `response.data.relationships.storage.data.id`. | Follow the upload tutorial; at the storage step `POST projects/:project_id/storage` and use `response.data.id`. |

`Get-OSSSignedUrl` in `templates/da/APS-Common.ps1` is the older signed-URL route and still works. `New-OSSObjectArgument` builds the URN form. Neither is the only way; pick the URN form when the files already sit in OSS, Forma and no signed URL is needed. The token goes in the WorkItem, so it never belongs in a file you commit or a chat message.
