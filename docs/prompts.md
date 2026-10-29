# Demo prompts

Prompts used to test and record the skill. Copy each as one line. Start Claude Code from an empty
folder with `claude --plugin-dir <path to this repo>`, with the five-value `.env` in that folder or a
parent folder.

## 1. Forma drawing

```
/aps-da-acad-c3d:aps-da-acad-c3d Create a aps automation application to extract layers to layers.json from `city-planning.dwg` version 2 in Forma - The  link <Forma folder link> Use - Auto mode.
```

Expected: `layers.json` on local disk with 20 layers. Follow-up used in the test: "Put layers.json back into Forma".

## 1b. Forma drawing, result back in the same folder (single prompt, for the recording)

```
/aps-da-acad-c3d:aps-da-acad-c3d Create a aps automation application to extract layers to layers.json from `city-planning.dwg` version 2 in Forma - The link <Forma folder link> Then put layers.json back into Forma, in the same folder as the drawing. Use - Auto mode.
```

Expected: `layers.json` saved locally, and a single `layers.json` created in the same Forma folder as `city-planning.dwg`. Before recording, delete any existing `layers.json` and `city-planning-layers.json` from that folder so the file is created, not versioned.

## 2. Local drawing

```
/aps-da-acad-c3d:aps-da-acad-c3d Create an APS automation application to extract layers to layers.json from `city-planning.dwg` in this folder. Use auto mode.
```

Expected: `layers.json` under `da\workitem-results`, no service account involved.

## 3. Local test with accoreconsole

Add the install folder at the end of any prompt so the skill runs the plugin locally before deploying. Any folder that holds `accoreconsole.exe` works.

```
/aps-da-acad-c3d:aps-da-acad-c3d Create an APS automation application to extract layers to layers.json from `city-planning.dwg` in this folder. Use auto mode. AutoCAD is installed at C:\Program Files\Autodesk\AutoCAD 2027
```

Expected: a local `accoreconsole` run that writes `layers.json`, then the cloud deploy and WorkItem.
