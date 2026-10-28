---
type: llm
focus: trace
weight: 1
---

Because the layer plugin takes no parameters, the response declares no params parameter and creates no params file for the activity. After the user's own request is fulfilled it offers the web app, and any description of how completion is reported uses the onComplete callback or the WebSocket API, never polling.
