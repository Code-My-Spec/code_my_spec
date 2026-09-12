defmodule CodeMySpec.CodeMode.Bindings do
  @moduledoc """
  Projects a catalog of tools into a VM as callable Lua functions, and captures
  what a script prints.

  ## The shape a tool takes in Lua

      local story = get_story({ story_id = "970" })

  One table in, the tool's result out. A tool that fails returns Lua's
  two-value idiom — `nil` plus an error table — rather than raising:

      local story, err = get_story({ story_id = "nope" })
      if story == nil then return "could not read it: " .. err.message end

  Returned rather than raised because a raise ends the script. Half of what
  code mode is for is a script that reads twenty things and reports on the
  three that were missing, and it cannot do that if the first miss kills it. A
  script that would rather stop can still write `assert(get_story{...})`.

  ## Scope is bound before this module sees anything

  Each tool's `invoke` closed over the caller's scope when the catalog was
  built, so a script acts with exactly the authority of the agent that sent it.
  Nothing reachable from Lua can change that: a script supplies arguments, and
  arguments are not where authority comes from.
  """

  require Logger

  alias CodeMySpec.CodeMode.Catalog
  alias CodeMySpec.CodeMode.LuaValue

  @printed :code_mode_printed

  @doc "Binds every tool in `catalog`, plus a capturing `print`."
  @spec install(Lua.t(), Catalog.t()) :: Lua.t()
  def install(lua, catalog), do: install(lua, catalog, [])

  @doc """
  The same, with the tools this agent's type does not carry bound to a stub.

  Bound rather than absent, for the reason `explain_exclusions/1` gives one line
  down: absence produces "attempt to call a nil value", which reads as a
  misspelling. An agent told that about a tool it knows exists tries variations
  of the name instead of learning it is not for it.
  """
  @spec install(Lua.t(), Catalog.t(), [String.t()], String.t() | nil) :: Lua.t()
  def install(lua, catalog, out_of_scope, kind \\ nil) do
    Process.put(@printed, [])

    lua
    |> capture_print()
    |> bind_tools(catalog)
    |> explain_exclusions()
    |> explain_scope(out_of_scope, kind)
  end

  @doc """
  What the script printed, in order — up to wherever it got to.

  Process-scoped rather than carried in the Lua state, on purpose
  (b9f4e5d4). `CodeMode.run/3` rebinds `lua` from `Lua.eval!`'s return, so a
  script that raises — a rejected tool call, a compile error — leaves `lua`
  in the `rescue` clause holding the *pre-eval* state, whose captured prints
  are always empty; the state `eval!` actually produced is discarded with the
  exception, and the `lua` package exposes no way to get it back. Each
  `CodeMode.run/3` call already executes in its own `Task`
  (`Sandbox.with_timeout/2`), so the process dictionary is exactly as
  privately scoped as the Lua state was meant to be, and survives the one
  case the state does not: a raise.
  """
  @spec printed() :: [String.t()]
  def printed, do: Process.get(@printed, [])

  # `print` writes to real stdout otherwise, which on a server means a script's
  # debugging lands in the server log and never reaches the agent that wrote it.
  defp capture_print(lua) do
    Lua.set!(lua, [:print], fn args, state ->
      line = Enum.map_join(args, "\t", &render/1)
      Process.put(@printed, Process.get(@printed, []) ++ [line])
      {[], state}
    end)
  end

  defp render(value) when is_binary(value), do: value
  defp render(value) when is_boolean(value), do: to_string(value)
  defp render(value) when is_float(value), do: value |> LuaValue.from_lua() |> to_string()
  defp render(value) when is_number(value), do: to_string(value)
  defp render(nil), do: "nil"
  defp render(value), do: inspect(value)

  defp bind_tools(lua, catalog) do
    Enum.reduce(catalog, lua, fn {name, tool}, acc ->
      Lua.set!(acc, [String.to_atom(name)], callback(tool))
    end)
  end

  # Bound so that calling one says why rather than failing as an unknown global.
  # Absence alone produces "attempt to call a nil value", which reads like a
  # misspelling — and an agent that reads it tries variations instead of
  # learning that the tool is direct-call only.
  defp explain_exclusions(lua) do
    Enum.reduce(Catalog.excluded(), lua, fn name, acc ->
      reason = Catalog.exclusion_reason(name)

      Lua.set!(acc, [String.to_atom(name)], fn _args, _state ->
        raise Lua.RuntimeException,
              "#{name} cannot be called from a script: #{reason}. Call it directly as a tool.\n\n" <>
                stale_list_note(name)
      end)
    end)
  end

  # The one case where "call it directly" is false, and the caller has no way to
  # tell.
  #
  # An MCP connection negotiates its tool list once, when it opens, and never
  # revisits it. So a session that outlives a server change keeps working
  # against the old surface with nothing reporting the skew — the same shape the
  # stop hook already detects and names for the harness/server channel, except
  # nothing detects it here.
  #
  # Measured 2026-09-12 (`9b08283d`): `promote` had just been registered, an
  # agent was told by `start_task` to call it, and got
  # "attempt to call a nil value" from a script and `Unknown tool` directly —
  # while `tools/list` over the proxy showed 19 tools including `promote` and
  # the session's own list carried 17. A `/mcp` reconnect surfaced it at once.
  #
  # Without this the refusal asserts the remedy confidently and the remedy does
  # not work, which is worse than the bare absence it replaced: an agent that
  # believes it has the tool reaches for spellings rather than for the
  # connection.
  defp stale_list_note(name) do
    "If calling `#{name}` directly answers `Unknown tool`, you do not have it — " <>
      "your MCP connection negotiated its tool list when it opened and has not " <>
      "revisited it, so a tool registered since then is missing from your side " <>
      "only. Reconnect (`/mcp`) and call it again."
  end

  # Named, and named as a scope decision rather than as an absence. The agent
  # asked for a tool that exists; what it needs to be told is that this kind of
  # agent does not carry it, so it stops looking and does something else.
  defp explain_scope(lua, out_of_scope, kind) do
    Enum.reduce(out_of_scope, lua, fn name, acc ->
      Lua.set!(acc, [String.to_atom(name)], fn _args, _state ->
        raise Lua.RuntimeException,
              "#{name} is not a tool #{describe(kind)} carries. It exists, and this " <>
                "kind of agent is not given it — asking again with a different " <>
                "spelling will not help."
      end)
    end)
  end

  # Named when we know it. "a qa agent cannot call delete_story" is a sentence
  # somebody can act on; "this agent cannot" leaves them wondering whether it is
  # about the type, the project, or the moment.
  defp describe(nil), do: "this agent"
  defp describe(kind), do: "a #{kind} agent"

  defp callback(tool) do
    fn args, state ->
      case call(tool, arguments(state, args)) do
        {:ok, value} ->
          {encoded, state} = Lua.encode!(state, value)
          {[encoded], state}

        # Stops the script. The tool never ran, so there is no answer to hand
        # back and nothing after this point can be standing on one. Returning
        # `nil, err` here is what let a script discard the second value, carry
        # on, and report a confident conclusion drawn from a call that did not
        # happen — which reads exactly like a tool that found nothing.
        {:invalid_call, message} ->
          raise Lua.RuntimeException, rejected(tool, message)

        {:error, message} ->
          {encoded, state} = Lua.encode!(state, %{"tool" => tool.name, "message" => message})
          {[nil, encoded], state}
      end
    end
  end

  # Names the tool, because a script makes several calls and one that fails
  # without saying which sends the reader through all of them. The rest of the
  # detail — which argument, what it wanted — is already in `message`.
  defp rejected(tool, message) do
    "#{tool.name} was called wrong and did not run: #{message}.\n\n" <>
      "The script stopped here. This is not an empty answer — nothing was " <>
      "read, so anything after this call would have been built on a call that " <>
      "never happened. Fix the call; `tool_docs({ name = \"#{tool.name}\" })`, " <>
      "called directly, gives its arguments and their types."
  end

  # A tool called with no arguments is the common case for the listing tools,
  # and Lua spells that `list_stories()` rather than `list_stories({})`.
  defp arguments(_state, []), do: %{}

  # The same conversion the return path uses. Without it only the top-level
  # keys were normalised, so a tool whose schema expects an array or a nested
  # object could not be called from a script at all — validation saw
  # `[{1, [{"name", "..."}]}]` and rejected it. `submit_qa_result` was the one
  # that found it, which an agent calls exactly once per QA session.
  defp arguments(state, [table | _rest]) do
    case state |> Lua.decode!(table) |> LuaValue.from_lua() do
      %{} = args -> args
      other -> %{"_" => other}
    end
  end

  defp call(tool, args) do
    tool.invoke.(args)
  rescue
    exception ->
      # A tool that crashes is a bug in the tool, not in the script, and the
      # script should be able to carry on and report it. Logged because nothing
      # else would notice a tool that only ever fails from inside a script.
      Logger.error("[CodeMode] #{tool.name} crashed: #{Exception.message(exception)}")
      {:error, "#{tool.name} crashed: #{Exception.message(exception)}"}
  end
end
