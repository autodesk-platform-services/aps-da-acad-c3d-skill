# Civil 3D in Design Automation

Verified in live WorkItems against the R26.0 / 2027 engine. Read this before writing any Civil 3D plugin.

## There is no separate Civil 3D engine

Civil 3D plugins run on the AutoCAD engine, `Autodesk.AutoCAD+26_0` for 2027. The engine's `CoreEngineVM` already contains the Civil object enabler, four shipped `.crx` modules, and the managed assemblies (`AeccDbMgd` and others). `AeccDbMgd` loads on demand. Confirm the engine id against `GET /da/us-east/v3/engines` rather than assuming it for other years.

`PackageContents.xml` for Civil uses `AutodeskProduct="AutoCAD"` and `Platform="AutoCAD*"`, with `SeriesMin` and `SeriesMax` set to `R26.0` for 2027.

## Project references

The upstream `templates/civil/` project is desktop-style: `net8.0-windows`, direct `Reference` entries to `AcMgd` and the Civil folders under `AcadDir`. The DA shape, which `templates/civil-da/` provides, is:

- `net10.0-windows`, x64.
- `AutoCAD.NET.Core` with `ExcludeAssets="runtime"`.
- `Civil3D.NET` with `ExcludeAssets="runtime"`. It ships full implementation DLLs, the same binaries baked into the engine, so the engine's own copy is the one that loads. If a WorkItem fails with a missing type or `MissingMethodException`, check version skew first: `Civil3D.NET` 13.9.628 is a known-good version.
- No `AcMgd`. The full `AutoCAD.NET` package crashes the headless core with `0xC0000005`.

## What actually ships

Only four native commands exist headless: LandXML import and export, IMX import and export, and `AeccExportCivilDrawing`. Corridor, alignment, and surface creation commands live in GUI-only `.arx` modules that never ship to DA. Reach those features through the Civil .NET API from your own bundle.

Verified in a live WorkItem: `Corridor.Rebuild()` runs and really recomputes (`IsOutOfDate` went true to false in about 0.4 s). Reversing the baseline alignment did not mark the corridor out of date; editing `BaselineRegion.EndStation` did.

## Calling command-only features

- LandXML import has no managed API. Use `ed.Command(".AeccLandXmlInNoDialog", path)`. A 23 MB repro file imported in about 29 s.
- `.IMX_IMPORT` has no NoDialog variant. It checks `FILEDIA`: set `Application.SetSystemVariable("FILEDIA", 0)` first so it prompts on the command line instead of opening a file dialog that would hang. Then `ed.Command(".IMX_IMPORT", path)`.
- Give extra datasets a fixed `localName` in `activity.json` (for example a generic `dataFile` parameter with `localName` `dataFile.dat`), and read `Path.Combine(Environment.CurrentDirectory, "dataFile.dat")`.

## Long operations

Rebuilds and large imports are silent, and a silent run is killed at about 60 seconds. The corridor rebuild's only progress callback is UI-bound code that never loads headless, so write your own heartbeat. See `da-guardrails.md`. Large imports can also hit time limits.

## Activity shape that worked

```json
{
  "id": "CivilCorridorRebuildActivity",
  "engine": "Autodesk.AutoCAD+26_0",
  "commandLine": [
    "$(engine.path)\\accoreconsole.exe /i \"$(args[inputFile].path)\" /al \"$(appbundles[CivilCorridorTest].path)\" /s \"$(settings[script].path)\""
  ],
  "parameters": {
    "inputFile":  { "verb": "get", "required": true, "localName": "input.dwg" },
    "outputFile": { "verb": "put", "required": true, "localName": "input.dwg" }
  },
  "settings": { "script": { "value": "TESTCORRIDORREBUILD\nQSAVE\n" } }
}
```

The script is a fixed setting here. Put `(handent "...")` or point answer lines between the command name and `QSAVE` when the command prompts.

## Other

- Not available in the cloud engine: Dynamo execution. VBA subassemblies are unverified.
- Always rethrow after logging so the WorkItem reports the failure.
- Use `StartTransaction()` only, never `StartOpenCloseTransaction()`, in the accoreconsole context.
