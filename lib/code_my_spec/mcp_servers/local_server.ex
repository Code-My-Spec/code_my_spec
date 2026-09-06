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

  alias Anubis.Server.Handlers
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.ScriptableTools

  use Anubis.Server,
    name: "codemyspec-local",
    version: "1.0.0",
    capabilities: [:tools]

  # Scope resolved from the X-Harness-Id header by `Plugs.HarnessScope`, which
  # reaches a tool's frame through the transport's assigns.

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
  component(CodeMySpec.McpServers.Tasks.Tools.SendMessage)
  component(CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion)
  component(CodeMySpec.McpServers.Tasks.Tools.CheckAnswer)
  component(CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions)
  component(CodeMySpec.McpServers.Tasks.Tools.AssignSubagent)
  component(CodeMySpec.McpServers.Tasks.Tools.TapOut)
  component(CodeMySpec.McpServers.Tasks.Tools.ShowInPanel)
  component(CodeMySpec.McpServers.Agents.Tools.StartAgent)
  component(CodeMySpec.McpServers.Agents.Tools.StopAgent)

  # Code mode itself.
  component(CodeMySpec.McpServers.CodeMode.Tools.ToolDocs)
  component(CodeMySpec.McpServers.CodeMode.Tools.RunScript)

  # The machine's tools — the browser's, mostly — get their own entry rather
  # than sharing `run_script`'s. They wait by design where ours answer in
  # milliseconds, so they need a deadline the caller sets; see the tool's own
  # docs. One schema for eighty-five tools, which is still the trade story 971
  # made.
  component(CodeMySpec.McpServers.CodeMode.Tools.RunBrowserScript)

  # ── A client that connected before the spine ──────────────────────────────
  #
  # A tool list is cached at connect, so a session that joined before story 971
  # still holds all 111 names and will call one that is no longer advertised.
  # Anubis answers that with `method_not_found`, which is true and unhelpful:
  # the tool exists, it moved, and the agent is one `run_script` call from it.
  #
  # Delegating to `Anubis.Server.Handlers.handle/3` rather than `super`:
  # Anubis defines `handle_request/2` in `__before_compile__`, which runs after
  # this module body, so there is no super to call yet. The delegation is
  # exactly what the generated clause does.
  @impl Anubis.Server
  def handle_request(%{"method" => "tools/call", "params" => %{"name" => name}} = request, frame) do
    case moved?(name) do
      true -> {:reply, moved_response(name), frame}
      false -> Handlers.handle(request, __MODULE__, frame)
    end
  end

  def handle_request(request, frame) do
    Handlers.handle(request, __MODULE__, frame)
  end

  defp moved?(name) do
    not Enum.any?(__components__(), &(&1.name == name)) and
      Enum.any?(ScriptableTools.__components__(), &(&1.name == name))
  end

  # `to_protocol/1`, not the struct. Anubis's own handler converts before
  # replying and this path bypasses it, so returning the struct hands the
  # transport something `JSON.Encoder` has no implementation for — which does
  # not merely fail the call, it **terminates the session**. That is worse than
  # the `method_not_found` this exists to improve on, and it shipped: the unit
  # test asserted on the struct it had just been handed, which is a tautology
  # at exactly the boundary that matters. QA on the real endpoint found it.
  defp moved_response(name) do
    Response.tool()
    |> Response.error("""
    #{name} is no longer called directly — it moved to code mode, along with
    most of this server's tools, so that connecting does not cost twenty
    thousand tokens of tool list.

    Call it from a script instead:

        run_script({ script = "return #{name}({ ... })" })

    `tool_docs({ name = "#{name}" })` gives its arguments.
    """)
    |> Response.to_protocol()
  end
end
