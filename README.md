# aps-da-acad-c3d

A Claude Code plugin that builds, deploys, and runs AutoCAD and Civil 3D plugins on APS Design Automation. Describe what you want, for example "extract the layers of this drawing to JSON". The drawing can be on local disk, at a URL, or in Forma. You get the result as a local file, a download link, or a new file in the same Forma folder.

Preview. Revit, Inventor, and Fusion are out of scope.

## Install

On Claude Code 2.1.275 or later:

```
/plugin install aps-da-acad-c3d --marketplace autodesk-platform-services/aps-da-acad-c3d-skill
```

Or from a clone: `claude --plugin-dir <path to this repo>`.

## Set up

1. An APS app with the Design Automation and Data Management APIs enabled.
2. A `.env` file in your working folder or any parent folder. These five values are all you provide:

   ```
   APS_CLIENT_ID=
   APS_CLIENT_SECRET=
   APS_NICKNAME=
   SSA_FIRST_NAME=
   SSA_LAST_NAME=
   ```

   The two `SSA_` values are for Forma input only. Claude never asks for, reads, or prints this file.
3. For Forma input you also need a [Secure Service Account (SSA)](https://aps.autodesk.com/en/docs/ssa/v1/developers_guide/overview/). Files in Forma are protected by user permissions, so your app's own token cannot read them or write back to them. An SSA is a non-human user of your app that signs in with a key, so Design Automation can work on those files without anyone signing in.

   An admin must register your client id under Custom Integrations and add the service account to the project. The skill checks this and prints a message you can send to your admin.

## Use it

Start Claude Code in an empty folder and give the whole request in one prompt:

```
/aps-da-acad-c3d:aps-da-acad-c3d Create an APS automation application to extract layers to layers.json from `city-planning.dwg` version 2 in Forma - <Forma folder link>. Put layers.json back into Forma, in the same folder as the drawing. Use auto mode.
```

- **Auto mode:** Claude runs everything. It assumes your values and admin steps are in place, and stops with a "switch to pair mode" hint if not.
- **Pair mode (default):** Claude gives you the commands and explains each step. You run them.

**Prompt guide: local test.** To test the plugin on your machine with `accoreconsole` before it goes to the cloud, end the prompt with your install folder, for example:

```
... Use auto mode. AutoCAD is installed at C:\Program Files\Autodesk\AutoCAD 2027
```

Any folder that holds `accoreconsole.exe` works. Without it the local test is skipped, and the real WorkItem is the only check.

More prompts: `docs/prompts.md`.

## Good to know

- Built and tested on Windows with PowerShell 7. AutoCAD or Civil 3D is needed only for the optional local `accoreconsole` test.
- macOS with PowerShell 7 is untested and may need changes. If you try it, please report what works and what doesn't in an issue.
- Keys: the service account key is saved in `~/.aps`, and the signing key in `da/mykey.json`. The skill adds a `.gitignore` for them.
- A hook blocks Claude from reading credential files. It matches command text, so treat it as a safety net, not a sandbox.
- Not yet run live: the WebSocket option with a signed submit, and creating a new service account from scratch.

## Issues

Found a problem or have an idea? Please open an [issue](https://github.com/autodesk-platform-services/aps-da-acad-c3d-skill/issues). Please open an issue before raising a pull request; see `CONTRIBUTING.md`.

## License

MIT. See `LICENSE`.

## Author

Madhukar Moogala, Autodesk Platform Services.
