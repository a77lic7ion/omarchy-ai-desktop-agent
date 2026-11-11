#!/bin/sh
# Hermes shell hook. Hermes pipes a JSON payload to stdin and parses stdout as a
# directive, so this script must print nothing.
#
# Wired from ~/.hermes/config.yaml:
#   hooks:
#     pre_tool_call:     [{command: .../agent-pet-hook.sh, matcher: ".*"}]
#     post_tool_call:    [...]
#     agent_loop_stopped: [...]
#     on_session_start:  [{command: ...}]
#     on_session_end:    [{command: ...}]

set -u

payload=$(cat)
[ -n "$payload" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

event=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty')
session=$(printf '%s' "$payload" | jq -r '.session_id // "default"')
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty')
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty')

case "$event" in
  pre_tool_call|post_tool_call|pre_verify)
    state="working"
    ;;
  post_llm_call|agent_loop_stopped|subagent_stop)
    state="done"
    ;;
  on_session_start)
    state="working"
    ;;
  on_session_end)
    state="idle"
    ;;
  *)
    exit 0
    ;;
esac

detail="$tool"
if [ -z "$detail" ]; then
  detail=$(basename "${cwd:-}")
fi

exec "$(dirname "$0")/../../bin/pet-event" \
  --agent hermes --session "$session" --state "$state" --detail "$detail"
