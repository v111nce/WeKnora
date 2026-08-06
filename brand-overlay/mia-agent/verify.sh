#!/usr/bin/env bash
set -euo pipefail

overlay_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$overlay_dir/../.." && pwd)"
overlay_file="$overlay_dir/agent-prompts.json"

for command_name in curl jq mktemp; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'ERROR: required command not found: %s\n' "$command_name" >&2
    exit 1
  }
done

base_url="${AI_STUDY_ABROAD_WEKNORA_BASE_URL:-http://127.0.0.1:18080/api/v1}"
agent_id="${AI_STUDY_ABROAD_WEKNORA_AGENT_ID:-$(jq -r '.target.agent_id' "$overlay_file")}"
expected_agent_name="${AI_STUDY_ABROAD_WEKNORA_AGENT_NAME:-$(jq -r '.target.agent_name' "$overlay_file")}"
canonical_file="${AI_STUDY_ABROAD_IDENTITY_FILE:-$repo_root/$(jq -r '.canonical_identity_source' "$overlay_file")}"

if [[ -z "${AI_STUDY_ABROAD_WEKNORA_API_KEY:-}" ]]; then
  printf 'ERROR: AI_STUDY_ABROAD_WEKNORA_API_KEY is required.\n' >&2
  exit 1
fi

if [[ -f "$canonical_file" ]]; then
  jq -e --slurpfile canonical "$canonical_file" '
    .canonical_identity == ($canonical[0] | {
      brand_name,
      assistant_name,
      identity_reply,
      technical_reply
    })
  ' "$overlay_file" >/dev/null || {
    printf 'FAIL: overlay identity differs from the ailx-agent canonical identity.\n' >&2
    exit 1
  }
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

agent_url="${base_url%/}/agents/$agent_id"
curl -fsS \
  -H "X-API-Key: $AI_STUDY_ABROAD_WEKNORA_API_KEY" \
  "$agent_url" >"$tmp_dir/current.json"

jq -e \
  --arg agent_id "$agent_id" \
  --arg agent_name "$expected_agent_name" \
  --slurpfile overlay "$overlay_file" '
  $overlay[0] as $config
  | ($config.identity_policy + "\n\n") as $identity_prefix
  | ($config.intent_prompts | with_entries(.value = ($identity_prefix + .value))) as $expected_intents
  | ($identity_prefix + $config.fallback_prompt) as $expected_fallback
  | .data as $agent
  | [
      ($agent.id == $agent_id),
      ($agent.name == $agent_name),
      ($agent.is_builtin == false),
      ($agent.config.intent_prompts == $expected_intents),
      ($agent.config.fallback_prompt == $expected_fallback),
      (($agent.config.intent_prompts | keys | sort) == (["greeting", "chitchat", "follow_up", "image_only", "summarize", "web_search", "doc_only"] | sort)),
      ([$config.system_prompt_patches[] | .marker as $marker | ($agent.config.system_prompt | contains($marker))] | all),
      ([$config.system_prompt_patches[] | .anchor as $anchor | ($agent.config.system_prompt | contains($anchor) | not)] | all),
      ([
        $agent.config.system_prompt,
        $agent.config.fallback_prompt,
        ($agent.config.intent_prompts[])
      ] | all(.[];
        contains("Mia")
        and contains("留学问问")
        and (test("WeKnora|Tencent|由腾讯开发"; "i") | not)
      ))
    ]
  | all
' "$tmp_dir/current.json" >/dev/null || {
  printf 'FAIL: agent %s does not match the Mia prompt overlay.\n' "$agent_id" >&2
  exit 1
}

printf 'PASS: agent %s matches the Mia prompt overlay and canonical identity.\n' "$agent_id"
