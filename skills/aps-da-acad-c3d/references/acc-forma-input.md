# Input drawing lives in ACC or Forma

Read this when the prompt starts like: "I have a drawing in FORMA/ACC (a link), version 2, my client id is provisioned, write an APS Automation application to ...". The plugin work is unchanged (see `SKILL.md`). What changes is how the WorkItem gets its input and where it puts its output. The object URN form is described in `da-guardrails.md` ("Object URNs for OSS, ACC, and Forma").

## Two paths: pick by where the data lives

Settle this before anything else about auth. A link to ACC or Forma means path 2, so do not ask; ask only when it is unclear where the drawing lives. The plugin is the same either way; only identity and WorkItem arguments change.

| | Path 1: confidential client | Path 2: SSA (data in ACC or Forma) |
|---|---|---|
| When | Server-to-server app. The app owner and the user are the same party. Inputs are a local file, OSS, or any URL the worker can reach. | The drawing lives in ACC or Forma and the run must act with a user's project permissions. |
| Identity | The app's own client id and secret (2-legged token, `code:all`). | A Secure Service Account (SSA), a non-human user of your app that signs in with a private key. No browser sign-in. |
| WorkItem submit | 2-legged token. No signature. | SSA (3-legged) token **plus a signature of the activity id**. |
| Activity | Any activity under your nickname. | The activity id you sign carries **your** nickname. An Autodesk activity such as `AutoCAD.PlotToPDF+prod` is usable by cloning its definition under your nickname, then signing `<nickname>.PlotToPDF+prod`. The public key must be registered first. |
| Input | Signed S3 URL from `Upload-ToOSS`, or a URN with a Bearer header. | Presigned S3 URL resolved with the SSA token (below). |
| Walk through | `SKILL.md` Steps 0 to 6, nothing more. | This file, in order. |

The 3-legged (SSA) token can call only `POST workitems` and `GET workitems/:id`. Creating the AppBundle and Activity, listing engines, and the OSS bucket for results all use the 2-legged app token.

ACC and Forma-hosted files are reached through the same Data Management API, and project, folder and version URNs have the same shape. The flow below has been exercised against ACC; Forma is expected to behave the same but has not been verified separately.

### Path 2 checklist, in order

1. **APS app:** Authentication, Data Management, Design Automation, and ACC Account Admin APIs enabled.
2. **ACC account admin** adds the app's client id under Custom Integrations. Without it ACC calls fail with 403. This is a human step; tell the user early because it can take a while to get.
3. **Find or create the SSA and a key. Check before creating.** A client id is often already provisioned: it may already have an SSA that is a project member, and its key PEM may already be on the machine. A new SSA has no project access, so creating one by default sends the user back to the admin for nothing. `Resolve-SsaConfig` in `templates/da/APS-Common.ps1` therefore runs automatically inside every script that needs an SSA token, from only `SSA_FIRST_NAME` and `SSA_LAST_NAME` (email `<first>-<last>@<client id>.adskserviceaccount.com`): an account with that email is reused (it prints `SSA: reusing ...`), and only if none exists is one created (`SSA: created ...`, which means the human steps below are still to do). For the account's key it looks for `<kid>.pem` in `~\.aps` (file names only; never open a PEM) before creating a new key there with current-user-only permissions. Nothing is written to `.env`. `templates/da/Setup-Ssa.ps1` is an optional pair-mode wrapper that runs the same resolution, prints the SSA email, and with `-Link` runs `Test-FormaAccess.ps1`. Never ask for the key or the secret. Then **add the SSA email to the project** as a member with Docs access and permission on the input folder (View and Download reads the file, upload and edit is needed to put results back; project admin works, but grant the least you can). To verify: `GET /construction/admin/v1/projects/<project-guid>/users?filter[email]=<ssa email>` with the SSA token (scope `account:read`).
4. **Choose a nickname** (up to 20 characters, `a-z A-Z 0-9 _`, no hyphen, different from the client id; set once per app). `Register-DaSigningKey` in `templates/da/APS-Common.ps1` generates the signing key pair and registers nickname plus public key in one step. Keep `mykey.json` out of git.
5. **Deploy the plugin** under that nickname (`Deploy-And-Test-DA.ps1`). The activity and alias already exist after the first success.
6. **Submit as the SSA:** resolve the file with the SSA token, compute `Get-ActivitySignature "<nickname>.<activity>+<alias>"`, then `Submit-WorkItem ... -signature $sig` with the SSA token. Poll with the same token. The signature is over the exact full id string, so the alias must match what you submit.

**Provisioned client id is not provisioned SSA.** Custom Integration registration belongs to the client id. Project membership belongs to each SSA email. Both must hold, and a 403 from the folder probe cannot say which is missing, so name both. Never print the admin steps unconditionally, and never assume they are missing: probe first with `templates/da/Test-FormaAccess.ps1 -Link <folder link>` (a folder listing with the SSA token). Exit 0 means go on; exit 2 means it printed the admin message for the user to send (relay it, wait, re-run); exit 1 means sign-in as the SSA failed (read the message). `templates/da/Run-FormaWorkItem.ps1` does the whole ACC read, signed submit and OSS output, and it takes the output name as a parameter.

A WorkItem submitted with an SSA token and no signature fails with "No public key can be found for this client" or a signature error. The fix is steps 4 and 6, not a different token.

## File resolution (read this first for path 2)

A lighter variant exists: use the app's 2-legged token for the DA calls and the SSA token only to read the file. That works for activities that need no signature, but the WorkItem then does not run as the SSA. The file-resolution steps are the same in both variants:

1. Get an SSA token (below) to resolve the ACC file. (Variant without signing: the 2-legged `code:all` token for every DA call.)
2. `GET https://developer.api.autodesk.com/data/v1/projects/b.<project-guid>/versions/<url-encoded versionId>/item` with the SSA token. In the response, find the `included[]` entry of type `versions`; `relationships.storage.data.id` is the OSS object URN and `relationships.storage.meta.link.href` is a storage link.
3. **Do not fetch that href directly.** It is OSS's legacy endpoint and returns 403 `Legacy endpoint is deprecated`. Append `/signeds3download` to the href's pathname (keep the `?scopes=...` query), call it with the SSA token, and read `url` from the response. That is a plain presigned S3 URL that needs no `Authorization` header.
4. The presigned URL expires fast (about 2 minutes). Resolve it immediately before submitting the WorkItem.
5. Submit the WorkItem with that URL as the input and an upload URL as the output (see Output).

**The version comes from the file link.** An ACC link to a file carries `entityId=urn:adsk.wipprod:fs.file:vf.<id>?version=<n>` in its query string (URL-encoded). That `entityId` is the version id used in step 2. A folder link, like the one in the typical prompt, has no `entityId`. Then list the folder with the SSA token: `GET /data/v1/projects/b.<project-guid>/folders/<folder urn>/contents?filter[type]=items&filter[displayName]-contains=<name>`, and take the tip version id from `included`. For "version 2", read the item's versions and pick that one. A 403 on the folder means the SSA lacks Docs access or folder permission (checklist step 3).

An alternative, not yet exercised end to end: pass the object URN straight in the WorkItem with `Authorization: Bearer <token>` in that argument's `headers` (see `da-guardrails.md`). Prefer the presigned URL route for a first run.

## What to take from the prompt

Parse the link instead of asking for what it already contains. Example shapes:

```
https://acc.autodesk.com/build/files/projects/<project-guid>?folderUrn=urn%3Aadsk.wipprod%3Afs.folder%3Aco.<id>&viewModel=detail&moduleId=folders
https://acc.autodesk.com/docs/files/projects/<project-guid>?folderUrn=...&entityId=urn%3Aadsk.wipprod%3Afs.file%3Avf.<id>%3Fversion%3D5
```

| From the link | Use |
|---------------|-----|
| `projects/<project-guid>` | Project id; Data Management uses it as `b.<project-guid>`. |
| `entityId` (URL-decode it) | The version id, when present. The `?version=<n>` part is the version number. |
| `folderUrn` | The folder, when there is no `entityId`. |
| "version 2" in the prompt | Which version to read; check it against `entityId` if both are given. |

Never ask for the client secret. If several files or versions match, show the candidates and let the user choose; do not pick silently.
## Output

Two reasonable choices; the user should pick:

- **An OSS bucket.** Use the app's 2-legged token with scope `data:read data:write bucket:create bucket:read`. Create a bucket (policy `transient` is fine; a bucket that already exists returns 409, which is OK to reuse; keys are lowercase letters, digits, dash, underscore, or dot, 3 to 128 characters). Then `GET /oss/v2/buckets/<bucket>/objects/<object>/signeds3upload` returns `uploadKey` and `urls[]`; give `urls[0]` as the output `url` with `verb: "put"`. **The argument's `verb` must be `put` even if the Activity declares `post`.** After the WorkItem succeeds, finalize with `POST .../signeds3upload` and `{ "uploadKey": ... }`, then `GET .../signeds3download` to read it back. Direct PUT and GET on OSS objects are deprecated.
- **Back into ACC or Forma.** Run `Run-FormaWorkItem.ps1 ... -PutBack` (optionally `-RemoteName`). If the result is already on disk, run `Put-FileInForma.ps1 -Link <folder link> -File <local file> -RemoteName <name>` instead; it uploads without running a WorkItem again. It uses `Publish-FileToAccFolder` in `APS-Common.ps1`: create a storage location in the folder, upload with a signed S3 URL, then register a new item, or a new version if that name already exists. The result lands in the same folder as the drawing, named `<drawing>-<OutputName>` by default. The SSA token needs `data:create` and the SSA needs upload and edit permission on the folder, so run `Test-FormaAccess.ps1 -Write` first; its admin message then asks for that permission. Written but not yet verified live.

## Authorization

DA calls use the 2-legged app token. Only reading (or writing) ACC project files needs a user-context token. Prefer a Secure Service Account (SSA), because nobody has to sign in.

A 3-legged (SSA) token can call only `POST /workitems` and `GET /workitems/:id`; any other DA endpoint fails with "3-legged tokens are only allowed...". Submitting with one also needs the activity-id signature (checklist step 4 and 6), or it fails with "No public key can be found for this client". Use the 2-legged token for everything else.

**Setting up an SSA** (what `Resolve-SsaConfig` in `APS-Common.ps1` automates):
- Get a 2-legged admin token with scopes `application:service_account:read application:service_account:write application:service_account_key:write application:service_account_key:read`.
- `POST https://developer.api.autodesk.com/authentication/v2/service-accounts` with `{ name, firstName, lastName }`. The response includes `serviceAccountId` and the account's `email`.
- `POST .../service-accounts/<serviceAccountId>/keys`. The response includes `kid` and `privateKey`. **The private key can be downloaded only once**, so save it immediately to a PEM file outside the repo. If the account already exists, `GET .../service-accounts` finds it, and `GET .../service-accounts/<id>/keys` lists keys; reuse one only if its PEM is saved locally.
- Add the SSA's `email` (`<name>@<client_id>.adskserviceaccount.com`) to the ACC or Forma project as a member (Members, Add members) with Docs access and folder permission. It is the likeliest first failure if reads return 403. Also confirm the token belongs to your app: its `client_id` claim should equal your client id.

**Getting the token** (`Get-SsaToken` in `templates/da/APS-Common.ps1` does this):
- Sign a JWT with RS256, `kid` in the header, and claims `iss` = client id, `sub` = service account id, `aud` = `https://developer.api.autodesk.com/authentication/v2/token`, `exp` = now + 300 seconds, `scope` = an array.
- POST it to that token URL with `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`, `assertion=<jwt>`, **and `scope=<space-separated scopes>` in the form body too**, using HTTP Basic client authentication. A working scope set is `data:read data:write code:all account:read` (`account:read` only for the membership check).
- Smoke-test the new token with a cheap call before the heavy steps. Reading the project's folder list is enough. Creating an ACC issue also works as a write test (pass `published: true`, or the issue is hidden in the UI).

Keep the PEM, the key id, the service account id, the client secret, and every token out of the conversation, out of committed files, and off screen. `aps-da-cli` has no SSA support and prints tokens to its console, so do not copy its token handling.

## Gotchas observed

- **Creating a duplicate SSA.** A script that defaults to a fixed SSA name creates a second account next to the provisioned one. List first, reuse, and only create when none exists.
- **A lost-looking key may exist locally.** PEM files are named by key id. Match by file name before creating another key.
- **Output file name.** The deploy script takes the output object name from the activity's `outputFile.localName`. A hardcoded `result.dwg` made a `layers.json` look like a downloaded drawing.
- **The secret-access hook also blocks boolean checks** such as "is `APS_SSA_*` set". In auto mode verify by running the scripts and reading their errors (`Missing APS_SSA_...`, 403), not by inspecting variables. Auto mode assumes everything is provisioned; if the scripts show it is not, tell the user to switch to pair mode.
- Keep `.pem` private keys, `mykey.json` (the activity-signing private key), and `.env` out of git: ignore `*.pem`, `mykey.json`, and `.env` before the first commit. Run logs contain presigned URLs; do not share them.
- Nickname: `a-z A-Z 0-9 _`, up to 20 characters, set once per app. A hyphen gives `nickname ... is invalid`.
- `activity ... could not be found` on the signed run: the activity or alias is not under your nickname yet. Deploy it first (or clone the Autodesk activity under your nickname).
- Rotate or delete unused SSA keys; give the SSA folder-level access, not project admin, once the flow works.
- Polling: a 5-minute poll is too short for a long WorkItem; `Wait-WorkItem` waits longer by default.

## Order of work

1. Confirm product year and install folder (Step 0 in `SKILL.md`).
2. Build, test locally with `accoreconsole`, and package the bundle. This step does not depend on ACC at all, so do it first and show it working.
3. Resolve the objectId and get a token (user-side).
4. Submit the WorkItem with the URN input and output.
5. Report the result and offer the next steps from Step 6.

Doing the plugin first means an ACC or token problem never blocks the part that can be verified without them.
