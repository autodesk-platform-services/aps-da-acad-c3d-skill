# APS Design Automation skill: workflow design

Status: draft for approval. Date: 2026-10-28.

## Intent and why

The `aps-da-acad-c3d` skill lets a citizen developer who has drawing data and a plain-language goal get a complete, working Design Automation sample. They run it on their own machine, with their own APS app, and can deploy it themselves. "Complete" means the plugin code and the infrastructure around it: AppBundle, Activity, service account, signing key, WorkItem submission, and output delivery.

This session mixed three roles and let skill development happen during a test run. Fixes landed in the sample project instead of the skill. This document separates the roles and defines when each kind of work and testing happens.

## Roles

| Role | Who | What they do | What they must not do |
|------|-----|--------------|-----------------------|
| Skill developer | The skill author | Edit the skill: SKILL.md, references, templates, scripts, hooks. Fix every gotcha at the source. | Fix problems only in a sample project. |
| Tester | The skill author, acting as a customer | Install the skill from a directory, give only the minimal inputs, judge the outcome, log failures. | Edit skill files during a run. A failure goes back to the developer role. |
| Citizen developer | The customer | Install the skill, fill in five values, give a prompt and a data location, do the admin steps only a human can do. | Edit skill internals, read or paste secrets in chat. |

## Citizen developer journey (the product)

1. **Install.** Install the skill (plugin directory during testing, a published plugin later).
2. **Provide five values** in a `.env` file anywhere in the project's folder or a parent folder (or at `APS_ENV_PATH`): `APS_CLIENT_ID`, `APS_CLIENT_SECRET`, `APS_NICKNAME`, `SSA_FIRST_NAME`, `SSA_LAST_NAME`. The skill never reads or asks for these in chat.
3. **Prompt.** Say where the drawing is (a local path, a Forma link, or another URL) and what they want, for example "extract layers to JSON."
4. **Skill asks only what it cannot infer:** product and year, what to extract, output form, and auto or pair mode.
5. **Skill builds:** scaffold from the template or worked example, build, local test where the product is installed, package the bundle.
6. **Skill deploys and runs:** AppBundle, Activity, SSA resolution, signing key, WorkItem.
7. **Skill delivers** one of: a file on local disk, a time-limited download link, or the result put back into the Forma folder beside the drawing.

## Modes

- **Auto (default for customers who provisioned everything).** The customer has supplied the five values, has a provisioned client id (Custom Integration registered), and the SSA is a project member. The skill runs every script itself and reads script output to learn what works. It never inspects secrets. If a script shows something is not provisioned (missing value, 403), it stops and tells the customer to switch to pair mode.
- **Pair.** The skill gives the exact commands and the customer runs them. It explains each step, including the human-only admin steps.

## Admin handoff (human-only steps, guided by the skill)

Two steps need a Forma account or project admin: registering the client id under Custom Integrations, and adding the SSA email to the project with Docs access and permission on the folder. The skill cannot do them, but it owns the guidance:

- **Detect.** It probes with a folder listing (the SSA token). Success means both are done and nothing is shown. A failure means one or both are missing.
- **Explain.** In plain words: what each step is, why it exists, and who can do it (account admin, project admin).
- **Hand over a ready-to-send request.** A short message the customer can paste to their admin, filled in from script output: the client id (not a secret), the SSA email, the project, the folder link, and the exact menu paths (Account Admin, Custom Integrations; Project, Members, add member, Docs access, folder permission). The skill never includes secrets.
- **Wait and resume.** The skill pauses, says how to confirm (re-run the probe), and continues from where it stopped once the probe passes. It does not repeat work already done.
- **Applies in both modes.** In auto mode this is the one expected stop; in pair mode it is part of the walkthrough.

## Infrastructure decisions (settled in this session)

- Input from Forma uses a Secure Service Account and a signed activity. Local, OSS or other URL input uses the app's own token.
- The SSA is found by email (`<first>-<last>@<client id>.adskserviceaccount.com`), reused if present, created only if absent. A client id being provisioned does not mean its SSA is a project member, so access is probed with a folder listing and the admin steps are printed only when the probe fails.
- The SSA key PEM is looked up by key id in `~/.aps`; a new key is created only if none is found.
- The signing key is generated and registered on first use if `mykey.json` is missing.
- The output file name comes from the activity's `outputFile` localName.
- The skill must not contain machine-specific paths, names or identifiers.

## Goals

- A customer goes from prompt to a verified result with five provided values and the unavoidable admin steps.
- Every failure mode seen in testing is prevented or diagnosed by the skill, not by the person.
- The delivered sample runs on the customer's machine and tenant, not only the author's.

## Non-goals

- Revit, Inventor and Fusion engines.
- A web front end or backend service, unless the customer asks (existing Step 6 stays offered, never unprompted).
- Automating the Forma admin steps (Custom Integration, project membership). They are human steps.

## Anti-goals

- A skill that works only because of the author's machine, paths, tenant or leftover files.
- Fixes that live only in a sample project.
- Any path where secrets reach the conversation, logs or committed files.
- Claiming a flow works before it was run live.

## Work remaining (skill developer)

1. **Put the result back into Forma** beside the drawing: create storage, upload with the SSA token, create the item, or a new version if the name exists. Not built, not tested.
2. **Setup-Ssa.ps1** to use the same `.env` lookup as the other scripts, or be retired in favor of automatic resolution.
3. **Signing key re-registration** for an already-set nickname: verify live what APS accepts.
4. **Skill behavior for the minimal prompt**: the skill asks the Step 0 questions, picks the worked example for "extract layers", selects the Forma run script, and offers output delivery. Review SKILL.md wording against this journey.
5. **Evals** for the journey: minimal prompt, missing-value stop with a pair-mode hint, existing SSA reuse, output name.

6. **Standalone access probe.** Today the probe lives inside `Setup-Ssa.ps1`. Auto mode needs a small script (or a step in the run script) that resolves the SSA, probes the folder, and prints the admin handoff details on failure, so the skill can run it without `Setup-Ssa.ps1`.

7. **Closing offer: full-stack web app.** After the user's intent is fulfilled and verified, the skill offers a web app: a Forma tree to pick project, folder and drawing, and a backend calling the Design Automation REST API with the tested activity, where only the WorkItem varies. The offer is in SKILL.md Step 6. The web app template itself (frontend, backend, tree via the SSA, polling) is not built; it is a separate project to design with its own brainstorm once the offer is accepted in a real run. Decided: there are two audiences. The citizen developer is the builder and deploys the app; the visitors are whoever uses the builder's app. Visitors sign in with their own Autodesk account (three-legged login) and see only what they can access; the service account is not used for visitors. The client secret and signing key stay on the server. WorkItems are submitted with the visitor's token and a signed activity under the builder's nickname; output goes to builder-controlled storage, or back into Forma with the visitor's own upload permission. Consequences the skill must explain to the builder: a callback URL and hosting are needed, and each visitor's Forma account must have the client id registered under Custom Integrations. Still open: where it is hosted and how the builder keeps secrets in that host.

Staging, so a first-time builder is not handed the whole picture at once:
- **Stage 1, team app on the builder's machine (the default).** Visitors are colleagues in the builder's own Forma account, where the client id is already registered, so there is no extra admin ask. Each person signs in with their own Autodesk account against `localhost`, so no hosting is needed. The app has a tree, a Run button and a result link.
- **Stage 2, deployed for others.** Adds hosting, a public callback URL, secrets handling on the host, and visitors from other Forma accounts, each needing the client id registered. The skill describes this and offers to continue; it does not build it in the first pass.

The skill asks one short question before building: "just my team, running locally, or deployed for others?" and defaults to the first. Nothing built in stage 1 is thrown away in stage 2.

## Test plan (tester role)

Gates are in order. Do not start a gate until the one before passes.

| Gate | When | Setup | Pass criteria |
|------|------|-------|---------------|
| T0, static | After each developer change | Parse-check scripts, build the example | No parse or build errors |
| T1, clean-room run, local file | After work items 2 and 3, and the review in item 4 | New empty folder, skill installed from its directory, five-value `.env`, prompt with a Forma folder link and "extract layers to JSON" | A valid `layers.json` on local disk with no manual fixes, no skill edits, and no secrets shown |
| T2, put back | After work item 1 | Same clean-room folder, prompt asks to put the JSON back into Forma | The file appears in the folder, openable in Forma |
| T3, pair mode and failure paths | After T1 | Remove one provisioned item at a time (SSA not a member, missing value) | The skill stops, names the missing item, and guides in pair mode |
| T4, outside pilot | After T1 to T3 | One real citizen developer on their own machine and tenant | They finish unassisted, and anything they ask us goes back into the skill |

Test run rules: the tester role never edits the skill. Every failure is logged with the exact output and then fixed by the developer role in the skill, and the gate restarts from a clean folder.

## Left to the builder

- The put-back implementation details (Data Management calls, version handling).
- The exact wording of Step 0 questions and the stop messages.
- How evals are structured, following the repository's existing convention.
