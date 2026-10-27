# aps-da-acad-c3d

A Claude Code plugin with one skill that builds AutoCAD and Civil 3D .NET plugins for APS Design Automation.

Status: work in progress, internal for now. Revit, Inventor, and Fusion are out of scope.

## What it does

Give it your logic, such as "extract the layers of a drawing". The skill takes it from there:

1. Asks what it needs: AutoCAD or Civil 3D, product year, install folder, inputs, and where the output should go.
2. Writes a basic non-interactive .NET plugin from the templates.
3. Tests it locally with `accoreconsole`.
4. Packages it as an AppBundle and defines the Activity.
5. Smoke-tests it with a real WorkItem.

Inputs and outputs are decided per WorkItem, so the same plugin can read from and write to a local file, an OSS bucket, ACC, or Forma.

## Two ways to authenticate

| Where the drawing lives | Path |
|---|---|
| Local disk, OSS, or any URL the worker can reach | Confidential client: your app's own client id and secret. Nothing else to set up. |
| ACC or Forma | Secure Service Account (SSA) with a signed activity. See `skills/aps-da-acad-c3d/references/acc-forma-input.md`. |

## Requirements

- Windows, with AutoCAD or Civil 3D installed (for `accoreconsole`).
- A .NET SDK that matches your product year.
- PowerShell 7 for the SSA scripts.
- An APS app with Design Automation and Data Management enabled.
- For ACC or Forma: an account admin who can add your client id as a Custom Integration, and a project admin who can add the SSA as a member.

## Try it

From an empty working folder:

```powershell
claude --plugin-dir <path to this repo>
```

Then ask in plain language:

```
I have a drawing at C:\path\to\sample.dwg. Write an APS automation application to extract layers. My client id is provisioned.
```

For a Forma drawing, give the link and the version:

```
I have a drawing in Forma <link>, version 2. My client id is provisioned. Write an APS automation application to extract layers.
```

## Credentials

- Put your client id and secret in `da/.env` yourself. Claude does not ask for them.
- The SSA private key goes in a PEM file outside the project. `templates/da/Setup-Ssa.ps1` creates it and fills in `da/.env` for you.
- A plugin hook (`hooks/Block-SecretAccess.ps1`) blocks Claude from reading `.env`, `*.pem`, and `mykey.json`, and from dumping environment variables. It matches command text, so treat it as a safety net, not a sandbox.
- You run the deploy and signing scripts in your own shell.

## Layout

```
.claude-plugin/plugin.json       plugin manifest
hooks/                           secret-access hook
skills/aps-da-acad-c3d/
  SKILL.md                       the skill
  references/                    DA guardrails, ACC and Forma input, Civil 3D notes
  templates/                     acad, civil, civil-da, and da (PowerShell) templates
  evals/                         eval cases for the skill
```

## Evals

The cases under `skills/aps-da-acad-c3d/evals/` run with `claude plugin eval`. Run `claude plugin eval --help` for the options. Results are written to `evals/results/`, which is ignored by git.

## Known gaps

- `Setup-Ssa.ps1`, the signing helpers, and the signed WorkItem submit have not been run against the live service yet.
- The ACC flow has been exercised. Forma is expected to behave the same but has not been verified separately.
- No marketplace listing yet. Install with `--plugin-dir` for now.
