---
name: aps-da-acad-c3d
description: "Build, test, and deploy AutoCAD and Civil 3D .NET plugins for APS Design Automation (DA). Scaffolds from the official acad (AutoCAD.NET.Core) and civil (Civil 3D) templates, writes non-interactive parameterized commands, produces the .bundle and PackageContents.xml, and authors the DA activity.json and params.json. Use whenever the user mentions Design Automation, APS DA, AutoCAD or Civil 3D automation in the cloud, accoreconsole, a WorkItem or Activity or AppBundle, or wants a headless .NET plugin for AutoCAD or Civil 3D, even if they never say 'skill' or 'template'. Covers AutoCAD and Civil 3D only."
argument-hint: "What the plugin should do (e.g., 'Civil 3D DA plugin that exports parcel areas to JSON')"
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# APS Design Automation for AutoCAD and Civil 3D (.NET)

Produces a .NET plugin that runs in an APS Design Automation WorkItem, for **AutoCAD** or **Civil 3D** only. Revit, Inventor, and Fusion engines are out of scope.

What it delivers, end to end: a basic plugin that implements the user's logic, tested locally with `accoreconsole`, packaged as an AppBundle, registered with an Activity, and smoke-tested with a real WorkItem. Getting inputs in and results out is a per-WorkItem concern, so the same plugin can serve OSS buckets, ACC, or Forma.

Why this skill exists: DA runs a headless `accoreconsole` in an Autodesk-hosted worker. There is no display and no message pump, so GUI is out. Command-line prompts are fine, though: `Editor.GetEntity`, `GetPoint`, `GetString` and the rest read their answers from the `/s` script that `accoreconsole` runs, exactly like a local `.scr`. Every prompt therefore needs a scripted answer, and a prompt with no answer fed is what stalls a WorkItem.

## Step 0 — Pick the target and gather paths

Ask once, then remember for the session. Skip any answer the user already gave.

| # | Ask | Used for |
|---|-----|----------|
| 1 | **AutoCAD or Civil 3D?** | Template choice, DA engine, bundle series |
| 2 | **Product year** (e.g. 2027) | `AcadVersion` NuGet, `SeriesMin/SeriesMax`, engine id |
| 3 | **Install folder** (AutoCAD or Civil 3D) | `accoreconsole.exe` path for local tests, Civil assembly references |
| 4 | **What should the command do, and what inputs does it need?** | Parameter record, `params.json` shape |
| 5 | **What output do you want, and where should it go?** | Output format, the `put` argument, and any extra library (see "Choose the output") |
| 6 | **Where does the input drawing live: local disk or any URL, or ACC/Forma?** | Auth path. Local, OSS, or other URL: confidential client (the app's own 2-legged token), nothing more to set up. ACC or Forma: a Secure Service Account (SSA) with a signed activity. Walk through `references/acc-forma-input.md` |

Never ask for, accept, or echo APS credentials. They go in `da/.env`, filled in by the user. Never open, search, or print `.env`, `*.pem`, or `mykey.json`; a plugin hook blocks those calls, and a block means ask the user, not find a workaround. If the user pastes a secret anyway, do not repeat it and tell them to rotate it. See "Credentials" in `references/da-guardrails.md`.

## Step 1 — Scaffold from the template

Templates live in `templates/` next to this file. They are copies of the upstream `acad-dotnet` templates; do not hand-write a project that duplicates them.

| Target | Template | Package or references | Notes |
|--------|----------|-----------------------|-------|
| AutoCAD | `templates/acad/` | `AutoCAD.NET.Core` NuGet, `net10.0-windows` for 2027 | `dotnet new acad` via `.template.config`; includes the `.bundle` folder and a post-build target that fills `Contents/` and zips on Release |
| Civil 3D | `templates/civil-da/` | `AutoCAD.NET.Core` plus `Civil3D.NET` NuGet, both `ExcludeAssets="runtime"` | DA-shaped csproj proven in live WorkItems. Read `references/civil-da.md` first. Use `templates/civil/` only for its `Cmd.cs` sample logic; its csproj is desktop-style (`net8.0-windows`, `AcMgd`, machine-specific `AcadDir`) |
| Both | `templates/da/` | PowerShell | `APS-Common.ps1`, `Deploy-And-Test-DA.ps1`, `Reset-APSApp.ps1`, `.env.example` |

Copy the template into the user's project folder, then replace the `$RootNamespace$`, `$ClassName$`, `$AcadVersion$` style tokens by hand if `dotnet new` is not installed. Read `templates/acad/README.md` or `templates/civil/ReadMe.md` for the template's own usage notes.

**The templates are starting points, not DA-ready as shipped:**

- `acad/ClassName.cs` registers a command that uses `Application.DocumentManager.MdiActiveDocument.Editor`. That works in `accoreconsole`, but keep `Editor` use to `WriteMessage` only.
- `civil/Civil/Cmd.cs` calls `Editor.GetEntity` (`PromptForEntity`) to pick a parcel. That works in DA as long as the script feeds the answer, for example `(handent "2A3")` when the parcel's handle is known beforehand. Decide with the user: keep the prompt and feed it from the script, or read the handle or name from a parameter file instead.
- `civil` references `AcMgd`, the desktop UI assembly, which crashes the headless core. Use the `civil-da` csproj instead.

## Step 2 — Write non-interactive commands

Every `[CommandMethod]` must satisfy all of these:

1. **No GUI.** No file dialogs, WinForms, or WPF. Command-line prompts (`GetEntity`, `GetPoint`, `GetString`, `GetKeywords`, `GetSelection`, ...) are allowed, but each one must have an answer in the script.
2. **Choose how each input is supplied, and say which in the code comments:**
   - *Script-fed prompt.* The script answers the prompt in order: a handle as `(handent "2A3")` for entity prompts, coordinates like `10,20,0` for points, text or a keyword for string prompts. Use this when the value is known before the WorkItem runs and the command is also used interactively. The script and the command's prompt sequence must stay in lockstep, so list the expected prompts in the command's doc comment.
   - *Parameter file.* Deserialize a small record from a JSON file the Activity maps in (conventionally `params.json`). Use this for structured or many-valued input. Keep the record in `Models/`, and keep the logic in helper classes so it can be unit tested without AutoCAD types.
3. **Output goes to a mapped file.** Write results (JSON, CSV, a modified DWG) to the working directory under the name the Activity declares. The acad template's `result.txt` is the pattern.
4. **Fail loudly.** Catch exceptions, log them with `WriteMessage` (DA captures the console report), then rethrow or exit non-zero. Do not swallow errors; a silent failure looks like success in a WorkItem.
5. **Transactions.** Wrap database work in `using` transactions and commit explicitly.

Package rule for AutoCAD: reference `AutoCAD.NET.Core` only, never the full `AutoCAD.NET` package. The full package pulls in `AcMgd.dll` and crashes the headless core with `0xC0000005`.

For API specifics, the upstream skill keeps `autocad-api.md` and `civil3d-api.md` references. Consult them (https://github.com/autodesk-platform-services/skills/tree/main/skills/acad-dotnet/references) rather than guessing member names.

## Choose the output — ask, do not assume

If the prompt does not say where results should go or what they should look like, ask once. Offer a default so the user can just say "fine".

**Where it goes** (set by the WorkItem's `put` argument, so the plugin does not change):

| Choice | When it fits |
|--------|--------------|
| A time-limited download link (a signed URL to an OSS object) | Default for a first run and for "give me a file". Say that the link expires, and offer to re-sign it. |
| Download to the user's machine | What `Deploy-And-Test-DA.ps1` already does. Good for testing. |
| Back into ACC or Forma | When the input came from there and the user wants the result beside it. See `references/acc-forma-input.md`. |
| Another storage service | Ask for a URL the worker can reach and the header it needs. |

**What it looks like** (this decides what the plugin writes):

| Format | Notes |
|--------|-------|
| JSON | Simplest, and the best base for any other format. |
| CSV | Opens in Excel with no extra library. Offer it first when the user says "Excel" casually. |
| HTML report | Write one self-contained file: inline CSS, no external scripts or fonts, so it opens anywhere from a download link. Escape every drawing-derived string (block names and attribute values can contain `<` or `&`). |

These are starting points, not a fixed menu. Work out the right output with the user as the task unfolds. If a format would need a new library in the bundle (a spreadsheet writer, for example), say why and get the user's agreement first, and prefer a format that needs none. When what to extract is ambiguous, ask instead of guessing. Keep the extraction logic in a helper that returns a plain data model, with small separate writers per format, so changing format later does not touch the drawing code.

## Step 3 — Bundle

- `PackageContents.xml` lists only the commands that DA should expose. Set `SeriesMin` and `SeriesMax` to the product year (the template ships `R26.0`, which is 2027). Never list dev-only commands such as a seed-drawing generator.
- Build in Release so the template's post-build target produces `<Name>.bundle.zip`. DA needs the zip with the `.bundle` folder at its root.
- Civil 3D: the bundle must also work when only the Civil engine's assemblies are present; do not copy Autodesk assemblies into `Contents/`.

## Step 4 — Author the DA definitions

Write `da/activity.json` and `da/params.example.json` per plugin. The deploy script reads the engine, command line, and parameters from them.

- `engine`: the AutoCAD engine id for the product year, e.g. `Autodesk.AutoCAD+26_0` for 2027. Civil 3D plugins use the same AutoCAD engine; there is no separate Civil engine. Confirm the string with `GET /da/us-east/v3/engines` for other years.
- WorkItem: every WorkItem body you write sets `"LimitProcessingTimeSec": 3600` at the top level, beside `activityId` and `arguments` (a complete example is in `references/da-guardrails.md`, "Object URNs for OSS, ACC, and Forma"). Send nothing else extra (the helper in `templates/da/APS-Common.ps1` does). Do not add `adskHeartbeatTimeoutInMin` or `adskDebug` up front; they are retry tools, covered under "When a WorkItem fails". A command that can run longer than a few seconds without output still needs a heartbeat writer in code, because about 60 seconds of silence kills the job.
- `commandLine`: write it **JSON-escaped**, because a single `\` before `accoreconsole` is an invalid JSON escape and `Deploy-And-Test-DA.ps1` fails to parse the file. In `activity.json` it reads `"$(engine.path)\\accoreconsole.exe /i \"$(args[inputFile].path)\" /al \"$(appbundles[<bundle>].path)\" /s \"$(settings[script].path)\""`. Check the file parses (`Get-Content da\activity.json -Raw | ConvertFrom-Json`) before handing the deploy command over. The command line uses a script that runs the command by name and then feeds one line per prompt, in prompt order. Test the same script locally with `accoreconsole /s` before deploying; if it stalls there, it will stall in DA. Whether the script is fixed in the Activity or supplied per WorkItem is a design choice: per-WorkItem is needed when handles or points change between runs.
- Reuse the input's `localName` for `outputFile` so the final `QSAVE` writes the file DA uploads. This avoids an untested `SAVEAS` step.
- Every ID in a WorkItem or Activity must be fully qualified (`<nickname>.<id>+<alias>`). The scripts already do this; keep it if editing REST calls by hand.

## Step 5 — Test, in this order

1. Unit tests for pure logic (math, parsing, parameter validation). No AutoCAD types.
2. Local `accoreconsole` run against a seed DWG with a `.scr` that does `NETLOAD` then the command. Every path handed to `accoreconsole` must be absolute.
3. Real DA run: the user runs `da/Deploy-And-Test-DA.ps1 -InputDwg <seed.dwg>` in their own shell. You can help interpret the output without seeing credentials.

If a seed DWG is needed and the user has none, see `references/da-guardrails.md` for generating one headlessly.

## Step 6 — After the first success: what next

When `Deploy-And-Test-DA.ps1` succeeds, the two heavy pieces are done and persist in the Automation service: the AppBundle (versioned, reached through an alias such as `dev`) and the Activity. Tell the user plainly that **the only thing that varies from here is the WorkItem**: the input file URL, the parameters, and the output URL. Offer these paths, smallest first:

1. **Keep running it from the console.** `Deploy-And-Test-DA.ps1` is a good test harness and enough for one-off jobs and regression checks.
2. **Call it from a backend.** Any language can do what the script does: get a 2-legged token, upload inputs to OSS and sign URLs, `POST workitems`, poll `GET workitems/:id` until it finishes, download the result. Node.js, Python, and C# all work.
3. **Put a web app in front of it.** A UI captures what the user wants and the backend turns that into a WorkItem (building the parameter JSON, uploading the DWG, returning the result). Keep the APS client secret on the server only, never in browser code. Start with polling; a completion callback needs a publicly reachable URL, so add it later.

**Inputs and outputs can live somewhere other than OSS (for example ACC or Forma).** Where files come from and go to is decided per WorkItem, in its `url` fields, not in the plugin or the Activity. So the plugin you already built and tested does not change; only the WorkItem arguments do. When the user says their files are in ACC or Forma, offer to adapt the WorkItem and the backend for that. For anything stored in OSS, ACC, or Forma Data Management, a WorkItem `url` can be an object URN instead of a signed S3 URL, with the access token in `headers`. Details and an example are in `references/da-guardrails.md` ("Object URNs for OSS, ACC, and Forma"). The short version: build `urn:adsk.objects:os.object:<url-encoded bucket>/<url-encoded object>`, send `Authorization: Bearer <token>`, and Automation handles signing, token refresh, and multi-part upload. The token needs `data:read` for inputs and `data:write` for outputs, and ACC or Forma buckets need a user-context token: an SSA token (preferred, nobody signs in). A WorkItem submitted with an SSA token must run a **signed activity under the user's own nickname**; `references/acc-forma-input.md` has the ordered checklist, and `Register-DaSigningKey` / `Get-ActivitySignature` in `templates/da/APS-Common.ps1` do the signing. For other storage services, a URL the worker can reach plus whatever header that service needs; ask the user which.

Credentials for any of these stay on the server side and out of the conversation, same as the APS client secret.

Re-deploy only what changed: new plugin code means a new AppBundle version and moving the alias; a changed command line or parameter list means a new Activity version. A WorkItem change needs neither. Promote from `dev` to a production alias once the run is stable.

Ask which path the user wants before writing any backend or UI code; do not scaffold one unprompted.

## When a WorkItem fails

Read the failure first, then offer one targeted retry; the table is in `references/da-guardrails.md`.

- **Time limit or timeout error:** add a heartbeat writer if missing, then retry with `adskHeartbeatTimeoutInMin` (1 to 10) in the WorkItem `arguments`.
- **Crash or odd behavior in plugin code:** offer to retry with `adskDebug: { uploadJobFolder: true }` in `arguments` so the job folder can be inspected.

Offer these as suggestions. Do not put them in the first submission.

## Working with the user

Deploy, signing, and any script with side effects are run by the user in their own shell. Hand over the exact command and wait for the output; do not run `Deploy-And-Test-DA.ps1` or `Reset-APSApp.ps1` yourself.

## References

- `references/da-guardrails.md` — credentials, nickname gotchas, seed DWG generation, path-resolution bugs, reset procedure, heartbeat, the 3600 time limit, queue visibility. Read when deploying or when a WorkItem fails.
- `references/acc-forma-input.md` — the two auth paths (confidential client vs SSA), then, for ACC or Forma: the ordered SSA checklist (custom integration, project membership, nickname and signing key), reading the project and folder from the link, resolving the presigned URL, signed WorkItem submit, and choosing an output location. Read it before touching the WorkItem whenever the input is in ACC or Forma.
- `references/civil-da.md` — Civil 3D specifics: engine, packages, shipped commands, `FILEDIA`, `ed.Command` patterns. Read for any Civil 3D target.
