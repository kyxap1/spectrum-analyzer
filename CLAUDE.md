# Project instructions

## Code review

- `ce-code-review` in this repo defaults to the quick/light path: invoke it with `quick review` wording, never `mode:agent` or anything that forces the full multi-agent roster, unless the user explicitly asks for the full review in that turn.
- Cross-model peer review is disabled here (`.compound-engineering/config.yaml` sets `cross_model_review_mode: off`). Don't re-enable it or override it per-invocation without the user explicitly asking.

## Local data export

- The export is the base of a future agent control interface. A local agent on the same Mac already turns pedal parameters through the guitar MIDI controller's MCP server; it will drive this app through the export (start/stop capture, Set reference, Learn noise, Reset, choose N) and read analysis data, all without the UI.
- In plans and code, never assume the export stays read-only: keep the listener, paths and the versioned document extensible for commands. Loopback-only stays correct, since the agent runs on the same machine.
