defmodule CodeMySpec.McpServers.LocalServer do
  @moduledoc """
  Single MCP server for the local development environment.

  Exposes tools relevant to the local agent workflow.
  Story CRUD lives on the web server — only linking is local.

  ## A new tool needs three things, and two of them are not the server

  Adding or removing a `component(...)` registration below requires **all** of:

  1. `MIX_ENV=dev_cli mix compile` — the `:4004` build is not refreshed by a
     plain restart, only `_build/dev` is. `just refresh` does this now
     (`a2ff68fa`); before it did, the server ran two-day-old modules while
     every mtime looked current.
  2. A full server restart. The running BEAM binds its tool registry at boot,
     so a tool compiled in but not restarted into appears in `tools/list` and
     returns `MCP error -32603: Internal error` on invocation — the server has
     no handler module loaded for it.
  3. **Every already-running agent must reconnect** (`/mcp` in Claude Code).
     The client caches its tool list at connect, so a tool the server has
     compiled, loaded and answered on is still `No such tool available` to any
     session that connected earlier. A subagent shares its parent's transport
     and inherits the stale list with it.

  The third is not fixable from here, and it is the one that reads as a bug in
  the tool. Proven by bypassing the client entirely — raw JSON-RPC over HTTP
  (`initialize` → `tools/list` → `tools/call`) found the tool present and
  working at the same moment two live sessions were told it did not exist
  (`b2d9c616`). Nothing signals which of the three is missing, so when a tool
  call fails with "no such tool", check in that order rather than assuming the
  tool is wrong.
  """

  use Anubis.Server,
    name: "codemyspec-local",
    version: "1.0.0",
    capabilities: [:tools]

  # Scope resolved from the X-Harness-Id header by `Plugs.HarnessScope`, which
  # reaches a tool's frame through the transport's assigns.

  #
  # Story 971. Everything else moved to `ScriptableTools` and is reached with
  # `run_script`. Measured before the move: 111 tools, 82,591 bytes, ~20,600
  # tokens, paid by every agent at connect for a task that calls three or four.
  #
  # A tool belongs here for one of two reasons, and only those two.

  # The loop every session walks, in order. These stay direct because putting
  # Lua ceremony on the most-walked path in the product buys nothing.
  # ── The spine ─────────────────────────────────────────────────────────────
  #
  # Story 971. Everything else is registered on `ScriptableTools` and reached
  # with `run_script`. Measured before the move: 111 tools, 82,591 bytes,
  # ~20,600 tokens, paid by every agent at connect for a task that calls three
  # or four of them.
  #
  # A tool is here for one of two reasons, and only those two.

  # The loop every session walks, in order. Direct because putting Lua ceremony
  # on the most-walked path in the product buys nothing.
  component(CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement)
  component(CodeMySpec.McpServers.Requirements.Tools.SyncProject)
  component(CodeMySpec.McpServers.Tasks.Tools.StartTask)
  component(CodeMySpec.McpServers.Tasks.Tools.EvaluateTask)

  # Tools a script may not call. `CodeMode.Catalog` refuses to bind these —
  # `ask_user` waits on a person, `start_agent` spawns — and a tool excluded
  # from scripts *and* absent from here would be reachable by no route at all.
  component(CodeMySpec.McpServers.Tasks.Tools.AskUser)
  component(CodeMySpec.McpServers.Tasks.Tools.CheckAnswer)
  component(CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions)
  component(CodeMySpec.McpServers.Tasks.Tools.AssignSubagent)
  component(CodeMySpec.McpServers.Tasks.Tools.TapOut)
  component(CodeMySpec.McpServers.Tasks.Tools.ShowInPanel)
  component(CodeMySpec.McpServers.Agents.Tools.StartAgent)
  component(CodeMySpec.McpServers.Agents.Tools.StopAgent)
  component(CodeMySpec.McpServers.Agents.Tools.MessageAgent)

  # Code mode itself.
  component(CodeMySpec.McpServers.CodeMode.Tools.ToolDocs)
  component(CodeMySpec.McpServers.CodeMode.Tools.RunScript)

  # Tools a script may not call. `CodeMode.Catalog` refuses to bind these —
  # `ask_user` waits on a person and `start_agent` spawns, and a loop around
  # either means something nobody asked for. They have to stay here, because a
  # tool excluded from scripts *and* absent from this list is reachable from
  # nowhere.

  # BDD Rules — Three Amigos session artifacts (blue + green + red cards).
  # Lives under BddRules namespace to disambiguate from CodeMySpec.Rules
  # (the coding-convention markdown rules consumed by agent task prompts).

  # after the underlying file is fixed but a later run didn't re-check it.

  # and had no way to answer whether it was done, or to do it.
end
