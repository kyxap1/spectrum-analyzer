# Project instructions

## Code review

- `ce-code-review` in this repo defaults to the quick/light path: invoke it with `quick review` wording, never `mode:agent` or anything that forces the full multi-agent roster, unless the user explicitly asks for the full review in that turn.
- Cross-model peer review is disabled here (`.compound-engineering/config.yaml` sets `cross_model_review_mode: off`). Don't re-enable it or override it per-invocation without the user explicitly asking.
