# aps-da-acad-c3d

A Claude Code plugin with one skill that builds AutoCAD and Civil 3D .NET plugins for APS Design Automation, deploys them, runs them on your drawings, and delivers the result.

You describe what you want in plain language, for example "extract the layers of this drawing to JSON". The drawing can be on local disk, at a URL, or in ACC or Forma. The skill does the rest: plugin, AppBundle, Activity, WorkItem, and the result as a local file, a download link, or a new file in the same ACC or Forma folder as the drawing.

Revit, Inventor, and Fusion are out of scope.

## Install

From a marketplace, on Claude Code 2.1.275 or later:

```
/plugin install aps-da-acad-c3d --marketplace autodesk-platform-services/aps-da-acad-c3d-skill
```

Or load it from a local clone, for example to try changes:

```powershell
claude --plugin-dir <path to this repo>
```

## Before you start

1. **An APS app** with the Design Automation and Data Management APIs enabled (https://aps.autodesk.com/myapps).
2. **A `.env` file** in your working folder or any parent folder, with five values. Nothing else is needed; the scripts work out the rest.

   ```
   APS_CLIENT_ID=
   APS_CLIENT_SECRET=
   APS_NICKNAME=
   SSA_FIRST_NAME=
   SSA_LAST_NAME=
   ```

   `APS_NICKNAME` is your Design Automation owner prefix (letters, digits, underscore, up to 20 characters, no hyphen; set once per APS app). The two `SSA_` values are only for ACC or Forma input: your Secure Service Account's email is `<first>-<last>@<client id>.adskserviceaccount.com`. An account with that email is reused; if none exists one is created. `templates/da/.env.example` has comments. You fill this file in yourself; Claude never asks for, reads, or prints it.
3. **For ACC or Forma input only,** two steps that need an admin and cannot be automated:
   - an account admin registers your client id under Account Admin > Custom Integrations;
   - a project admin adds the service account's email to the project, with Docs access and permission on the folder (upload and edit if results go back into the folder).

   If either is missing the skill detects it, explains it, and prints a ready-to-send message for your admin.

## Try it

Start Claude Code in an empty folder with the plugin loaded, then give the whole request in one prompt.

A drawing in Forma, with the result back in the same folder:

```
/aps-da-acad-c3d:aps-da-acad-c3d Create an aps automation application to extract layers to layers.json from `city-planning.dwg` version 2 in Forma - the link <ACC folder link>. Then put layers.json back into Forma, in the same folder as the drawing. Use auto mode.
```

A drawing on local disk:

```
/aps-da-acad-c3d:aps-da-acad-c3d Create an APS automation application to extract layers to layers.json from `city-planning.dwg` in this folder. Use auto mode.
```

More prompts are in `docs/prompts.md`.

## Auto and pair modes

| Mode | What happens |
|---|---|
| Auto | Claude runs everything itself: scaffold, build, deploy, access check, WorkItem, result. It assumes your five values and your admin steps are already in place. If a script shows something is not provisioned, it stops, tells you to switch to pair mode, and gives you the admin message. |
| Pair (default) | Claude gives you the exact commands and explains each step, including the admin steps. You run the scripts in your own shell. |

## What the skill does

1. Takes defaults from your prompt (AutoCAD, the current product year, a local JSON file) and asks only what it cannot infer.
2. Creates a `.gitignore` in your project first (never overwriting an existing one) so credentials, signing keys, run output, and build output are never committed.
3. Writes a non-interactive .NET plugin from the templates or the worked example in `templates/layer-extract-example/`.
4. Tests it locally with `accoreconsole` when AutoCAD is installed; otherwise the real WorkItem is the verification.
5. Packages the AppBundle, registers the Activity, and runs a WorkItem.
6. For ACC or Forma input: checks access first, reads the drawing version you named, submits a signed WorkItem as the service account, and optionally puts the result back beside the drawing (a new file, or a new version if the name exists).
7. Offers next steps: keep running from the console, a backend, or a web app. A backend should use the Automation WebSocket API, and a web app the `onComplete` callback. Neither polls.

## Two ways to authenticate

| Where the drawing lives | Path |
|---|---|
| Local disk, OSS, or any URL the worker can reach | Confidential client: your app's own client id and secret. |
| ACC or Forma | Secure Service Account (SSA) with a signed activity. See `skills/aps-da-acad-c3d/references/acc-forma-input.md`. |

## Scripts

Copied into your project's `da/` folder from `skills/aps-da-acad-c3d/templates/da/`:

| Script | Purpose |
|---|---|
| `Deploy-And-Test-DA.ps1` | Registers the AppBundle and Activity and runs a test WorkItem on a local drawing. `-DeployOnly` skips the test WorkItem. |
| `Test-FormaAccess.ps1` | Checks that the service account can read (with `-Write`, upload to) a Forma folder; prints the admin message if not. |
| `Run-FormaWorkItem.ps1` | Reads a drawing from ACC or Forma, runs the Activity, saves the result. `-PutBack` uploads it back, `-UseWebSocket` reports completion over the WebSocket API, `-ShowLink` prints a time-limited download link. Started with no options it asks for each one. |
| `Setup-Ssa.ps1` | Optional pair-mode helper that finds or creates the service account and can run the access check. |
| `Reset-APSApp.ps1` | Deletes your Design Automation resources. Destructive; ask first. |
| `gitignore.template` | The `.gitignore` the skill puts in your project. |

## Credentials and keys

- Claude does not ask for, read, or print credentials. A plugin hook (`hooks/Block-SecretAccess.ps1`) blocks reads of `.env`, `*.pem`, and `mykey.json` and dumps of environment variables. It matches command text, so treat it as a safety net, not a sandbox.
- The service account's private key is saved in `~/.aps` as `<key id>.pem`, readable only by you. It is shown by APS only once, so keep that folder; an account can have only a limited number of keys.
- The activity-signing key is generated on the first signed run as `da/mykey.json` (with `mypublickey.json`) in your project. The `.gitignore` the skill creates covers it.
- Presigned URLs are credentials; the scripts do not print them unless you ask (`-ShowLink`).

## Requirements

- Windows, with AutoCAD or Civil 3D installed for the local `accoreconsole` test (optional).
- A .NET SDK that matches your product year.
- PowerShell 7 for the scripts.

## Layout

```
.claude-plugin/                  plugin.json and marketplace.json
hooks/                           secret-access hook
docs/                            demo prompts and the workflow design
skills/aps-da-acad-c3d/
  SKILL.md                       the skill
  references/                    DA guardrails, ACC and Forma input, Civil 3D notes
  templates/                     acad, civil, civil-da, da (PowerShell), layer-extract-example
  evals/                         eval cases for the skill
```

## Evals

The cases under `skills/aps-da-acad-c3d/evals/` run with `claude plugin eval`. Run `claude plugin eval --help` for the options. Results are written to `evals/results/`, which is ignored by git. Check the manifests with `claude plugin validate .`.

## Known gaps

- Verified end to end on live services: a Forma drawing to a local `layers.json`, putting the result back in Forma, and a local drawing. Not yet run live: the WebSocket option with a signed (service account) submit, creating a brand-new service account from scratch, and the evals added for auto mode and put-back.
- The web app offered at the end of a run is a design only; no template is built yet.
- Civil 3D templates are included but were not part of the recent end-to-end runs.
