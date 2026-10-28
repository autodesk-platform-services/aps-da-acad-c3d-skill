---
type: llm
focus: trace
weight: 1
---

Both of these appear in the response's steps. (1) A step that puts the gitignore template into the project root, never overwriting an existing file, comes before any step that creates the plugin, builds, or deploys (reading files does not count as creating). (2) The plugin starts from the worked layer-extract example, not from a plugin written from scratch.
