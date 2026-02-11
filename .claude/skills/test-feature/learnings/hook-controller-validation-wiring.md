# HookController -> Validation Module Wiring (Feb 2026)

## What was tested
Rewiring `HookController` from `ValidateEdits` + `EvaluateAgentTask` to the unified `Validation` module.

## Bug found: nil transcript_path crash
- Claude Code does NOT send `transcript_path` in its Stop hook payload
- `File.read(nil)` raises `FunctionClauseError`, not `{:error, _}`
- This crashed `Validation.validate_stop` -> `extract_edited_files` -> `Transcripts.parse`
- **Fix**: Added `defp extract_edited_files(nil), do: {:ok, []}` guard clause

## Hook data from Claude Code
The hook binary (`CodeMySpec/.claude-plugin/bin/hook`) passes stdin JSON straight through via curl.
Claude Code sends these fields in Stop hooks:
- `hook_event_name`, `session_id`, `cwd`, `agent_id`
- Does NOT send: `transcript_path`, `stop_hook_active`

For SubagentStop:
- Additionally sends `agent_transcript_path`

## Testing approach that worked
1. Start server: `mix cli server run` (background)
2. Smoke test with curl (fast feedback):
   - Stop with `stop_hook_active: true` -> verify short-circuit
   - Stop with real transcript fixture -> verify pipeline runs
   - SubagentStop with transcript fixture -> verify pipeline runs
3. Full integration: `claude --print --plugin-dir <path> -p "..." --allowedTools "..."` against test project
4. Monitor server stdout (not cli.log) for log entries

## Key observation
`--print` mode does not spawn subagents, so SubagentStop hooks won't fire in that mode. Only Stop hooks fire. For SubagentStop testing, use curl with transcript fixtures or interactive Claude mode.
