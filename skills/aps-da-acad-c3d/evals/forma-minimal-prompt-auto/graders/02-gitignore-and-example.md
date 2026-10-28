---
type: llm
focus: trace
weight: 1
---

Before creating other project files, the response puts the gitignore template into the project root (appending only missing entries if one exists, never overwriting) so the environment file, PEM files, the signing key and the results folder are ignored, and it starts the plugin from the worked layer-extract example instead of writing a new plugin from scratch.
