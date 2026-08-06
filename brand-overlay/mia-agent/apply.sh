#!/usr/bin/env bash
set -euo pipefail

overlay_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$overlay_dir/../.." && pwd)"
overlay_file="$overlay_dir/agent-prompts.json"
verify_script="$overlay_dir/verify.sh"

for command_name in cmp curl jq mktemp; do
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

jq -e '
  . as $config
  | $config.schema_version == "weknora_agent_prompt_overlay.v1"
    and ($config.identity_policy | contains($config.canonical_identity.assistant_name))
    and ($config.identity_policy | contains($config.canonical_identity.brand_name))
    and ($config.identity_policy | contains($config.canonical_identity.identity_reply))
    and ($config.identity_policy | contains($config.canonical_identity.technical_reply))
' "$overlay_file" >/dev/null || {
  printf 'ERROR: invalid Mia overlay configuration.\n' >&2
  exit 1
}

if [[ -f "$canonical_file" ]]; then
  jq -e --slurpfile canonical "$canonical_file" '
    .canonical_identity == ($canonical[0] | {
      brand_name,
      assistant_name,
      identity_reply,
      technical_reply
    })
  ' "$overlay_file" >/dev/null || {
    printf 'ERROR: overlay identity differs from the ailx-agent canonical identity: %s\n' "$canonical_file" >&2
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
  '.success == true
   and .data.id == $agent_id
   and .data.name == $agent_name
   and .data.is_builtin == false
   and (.data.config | type == "object")' \
  "$tmp_dir/current.json" >/dev/null || {
    printf 'ERROR: target must be the expected non-built-in agent: %s (%s).\n' "$expected_agent_name" "$agent_id" >&2
    exit 1
  }

jq -e --slurpfile overlay "$overlay_file" '
  def patch_replacement($patch; $config):
    if $patch.replacement_ref == "identity_policy" then $config.identity_policy
    elif ($patch.replacement | type) == "string" then $patch.replacement
    else error("unsupported replacement for patch " + $patch.id)
    end;
  def apply_exact_patch($text; $patch; $config):
    if $text | contains($patch.marker) then $text
    elif $text | contains($patch.anchor) then
      ($text | split($patch.anchor)) as $parts
      | if ($parts | length) != 2 then
          error("anchor is not unique for patch " + $patch.id)
        else
          $parts | join(patch_replacement($patch; $config))
        end
    else
      error("marker and anchor are both absent for patch " + $patch.id)
    end;

  $overlay[0] as $config
  | .data as $agent
  | (reduce $config.system_prompt_patches[] as $patch
      ($agent.config.system_prompt; apply_exact_patch(.; $patch; $config))) as $system_prompt
  | ($config.identity_policy + "\n\n") as $identity_prefix
  | {
      name: $agent.name,
      description: ($agent.description // ""),
      avatar: ($agent.avatar // ""),
      config: (
        $agent.config
        | .system_prompt = $system_prompt
        | .intent_prompts = ($config.intent_prompts | with_entries(.value = ($identity_prefix + .value)))
        | .fallback_prompt = ($identity_prefix + $config.fallback_prompt)
      )
    }
' "$tmp_dir/current.json" >"$tmp_dir/update.json"

jq -S '{system_prompt: .data.config.system_prompt, intent_prompts: .data.config.intent_prompts, fallback_prompt: .data.config.fallback_prompt}' \
  "$tmp_dir/current.json" >"$tmp_dir/before-prompts.json"
jq -S '{system_prompt: .config.system_prompt, intent_prompts: .config.intent_prompts, fallback_prompt: .config.fallback_prompt}' \
  "$tmp_dir/update.json" >"$tmp_dir/after-prompts.json"

if cmp -s "$tmp_dir/before-prompts.json" "$tmp_dir/after-prompts.json"; then
  printf 'Mia prompt overlay already applied to agent %s.\n' "$agent_id"
else
  curl -fsS \
    -X PUT \
    -H "X-API-Key: $AI_STUDY_ABROAD_WEKNORA_API_KEY" \
    -H 'Content-Type: application/json' \
    --data-binary "@$tmp_dir/update.json" \
    "$agent_url" >"$tmp_dir/response.json"

  jq -e --arg agent_id "$agent_id" '.success == true and .data.id == $agent_id' \
    "$tmp_dir/response.json" >/dev/null || {
      printf 'ERROR: WeKnora did not confirm the agent update.\n' >&2
      exit 1
    }
  printf 'Applied Mia prompt overlay to agent %s.\n' "$agent_id"
fi

AI_STUDY_ABROAD_WEKNORA_BASE_URL="$base_url" \
AI_STUDY_ABROAD_WEKNORA_AGENT_ID="$agent_id" \
AI_STUDY_ABROAD_WEKNORA_AGENT_NAME="$expected_agent_name" \
AI_STUDY_ABROAD_IDENTITY_FILE="$canonical_file" \
  "$verify_script"
