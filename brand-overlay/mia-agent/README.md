# Mia Agent Prompt Overlay

This directory isolates the 留学问问/Mia customization from the upstream
WeKnora source tree. It follows the overlay approach described in the production
deployment article: customization has an explicit owner, exact anchors, durable
markers, idempotent application, and fail-fast verification.

The prompt content is derived from the canonical identity contract in the
adjacent `ailx-agent` project:

```text
../ailx-agent/planner/skills/study-abroad-agent/references/identity-and-scope.json
```

`agent-prompts.json` includes a deployment snapshot of the four identity fields,
so the overlay remains usable when the projects are deployed separately. When
the canonical file is available, both scripts compare it with that snapshot and
fail if they differ.

## Scope

The overlay targets only the custom agent configured for 留学问问. It reads the
current agent through the WeKnora API, preserves all unrelated settings, and
updates only:

- `config.system_prompt`, using exact marker/anchor patches.
- `config.intent_prompts`, covering all seven non-retrieval intents.
- `config.fallback_prompt`, covering the model fallback branch.

It does not modify WeKnora's global prompt YAML, built-in agents, frontend
welcome text, OCR/parsing prompts, query rewriting, suggested-question prompts,
or other internal tasks that do not own the user-facing assistant identity. It
also never falls back to writing the database directly.

## Apply

The API key must be able to read the target agent and have `manage_agents` or
full access to update it.

```bash
export AI_STUDY_ABROAD_WEKNORA_API_KEY='...'
./brand-overlay/mia-agent/apply.sh
```

Optional overrides:

- `AI_STUDY_ABROAD_WEKNORA_BASE_URL`
- `AI_STUDY_ABROAD_WEKNORA_AGENT_ID`
- `AI_STUDY_ABROAD_WEKNORA_AGENT_NAME`
- `AI_STUDY_ABROAD_IDENTITY_FILE`

The operation is idempotent. If every target field already matches, no PUT is
sent. If a WeKnora upgrade changes an expected system-prompt anchor, application
fails instead of silently changing an unknown prompt.

## Upgrade Check

After updating WeKnora:

```bash
./brand-overlay/mia-agent/apply.sh
./brand-overlay/mia-agent/verify.sh
```

The verifier checks the target agent, all seven intent keys, exact prompt
content, system-prompt markers, removed legacy anchors, canonical identity, and
absence of the old platform/vendor identity in every user-facing prompt branch.
