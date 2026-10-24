defmodule CodeMySpec.CodeMode.Bindings do
  @moduledoc """
  Projects a catalog of tools into a VM as callable Lua functions, and captures
  what a script prints.

  ## The shape a tool takes in Lua

      local story = get_story({ story_number = 970 })

  One table in, the tool's result out. A tool that fails returns Lua's
  two-value idiom — `nil` plus an error table — rather than raising:

      local story, err = get_story({ story_number = 99999 })
      if story == nil then return "could not read it: " .. err.message end

  Returned rather than raised because a raise ends the script, and a script
  that reads twenty things should be able to report the three that failed. A
  script that would rather stop can write `assert(get_story{...})`.

  A call the tool rejected before running (`:invalid_call`) does raise: there
  is no answer for anything after it to stand on.

  ## Scope is bound before this module sees anything

  Each tool's `invoke` closed over the caller's scope when the catalog was
  built, so a script acts with exactly the authority of the agent that sent it.
  A script supplies arguments, and arguments are not where authority comes from.
  """

  require Logger

  alias CodeMySpec.CodeMode.Catalog
  alias CodeMySpec.CodeMode.LuaValue
  alias CodeMySpec.CodeMode.Progress

  @printed :code_mode_printed

  @doc "Binds every tool in `catalog`, plus a capturing `print`."
  @spec install(Lua.t(), Catalog.t()) :: Lua.t()
  def install(lua, catalog), do: install(lua, catalog, [])

  @doc """
  The same, with every known tool a script may not call bound to a stub that
  says why: excluded tools, tools out of this agent's scope, and other
  registered tools it does not carry.

  Bound rather than absent: absence produces "attempt to call a nil value",
  which reads as a misspelling. See knowledge/tools, "Refusals".
  """
  @spec install(Lua.t(), Catalog.t(), [String.t()], String.t() | nil, [String.t()] | :all) ::
          Lua.t()
  def install(lua, catalog, out_of_scope, kind \\ nil, carried \\ :all, direct \\ :all) do
    Process.put(@printed, [])

    lua
    |> capture_print()
    |> bind_tools(catalog)
    |> explain_exclusions(carried)
    |> explain_direct_names(direct)
    |> explain_scope(out_of_scope, kind)
  end

  @doc """
  What the script printed, in order — up to wherever it got to.

  Kept in the process dictionary, not the Lua state: a script that raises
  discards the state `Lua.eval!` produced, and its prints with it. Each
  evaluation runs in its own task (`Sandbox.with_timeout/2`), so the process
  dictionary is just as private.
  """
  @spec printed() :: [String.t()]
  def printed, do: Process.get(@printed, [])

  # Otherwise `print` goes to the server's stdout, never to the agent.
  defp capture_print(lua) do
    Lua.set!(lua, [:print], fn args, state ->
      line = Enum.map_join(args, "\t", &render/1)
      Process.put(@printed, Process.get(@printed, []) ++ [line])
      Progress.report({:print, line})
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

  # Excluded tools: calling one says why rather than failing as an unknown global.
  defp explain_exclusions(lua, carried) do
    Enum.reduce(Catalog.excluded(), lua, fn name, acc ->
      reason = Catalog.exclusion_reason(name)

      Lua.set!(acc, [String.to_atom(name)], fn _args, _state ->
        raise Lua.RuntimeException, exclusion_message(name, reason, carried)
      end)
    end)
  end

  # "Call it directly" only for a caller whose role carries the tool; telling
  # anyone else to call it (or to reconnect) sends them hunting for a fault that
  # does not exist. `:all` is a caller with no role scoped away (a person, an
  # operator session).
  defp exclusion_message(name, reason, carried) do
    if carried?(name, carried) do
      "#{name} cannot be called from a script: #{reason}. Call it directly as a tool.\n\n" <>
        stale_list_note(name)
    else
      "#{name} cannot be called from a script: #{reason}. " <>
        "It is also not a tool this kind of agent carries, so calling it directly " <>
        "will be refused too -- it belongs to another role. " <>
        "If you need what it does, say so rather than working around it."
    end
  end

  defp carried?(_name, :all), do: true
  defp carried?(name, carried) when is_list(carried), do: name in carried

  # An MCP client negotiates its tool list once, at connect, so a tool
  # registered since is missing on the caller's side only and nothing reports
  # the skew. The note names the remedy.
  defp stale_list_note(name) do
    "If calling `#{name}` directly answers `Unknown tool`, you do not have it — " <>
      "your MCP connection negotiated its tool list when it opened and has not " <>
      "revisited it, so a tool registered since then is missing from your side " <>
      "only. Reconnect (`/mcp`) and call it again."
  end

  # Named as a scope decision rather than an absence, so the agent stops
  # looking and does something else.
  defp explain_scope(lua, out_of_scope, kind) do
    Enum.reduce(out_of_scope, lua, fn name, acc ->
      Lua.set!(acc, [String.to_atom(name)], fn _args, _state ->
        raise Lua.RuntimeException,
              "#{name} is not a tool #{describe(kind)} carries. It exists, and this " <>
                "kind of agent is not given it — asking again with a different " <>
                "spelling will not help." <> substitute_hint(name)
      end)
    end)
  end

  # Registered tools that are neither scriptable nor this caller's
  # (`Catalog.direct_only/2`, computed by the caller), bound to a sentence
  # rather than left to the misspelling diagnostic. See knowledge/tools,
  # "Refusals".
  defp explain_direct_names(lua, :all), do: lua

  defp explain_direct_names(lua, direct) when is_list(direct) do
    Enum.reduce(direct, lua, fn name, acc ->
      Lua.set!(acc, [String.to_atom(name)], fn _args, _state ->
        raise Lua.RuntimeException, not_direct(name)
      end)
    end)
  end

  defp not_direct(name) do
    "#{name} is a tool on this server, but not one this kind of agent carries: it " <>
      "belongs to another role, so calling it directly will be refused too. It is " <>
      "not a misspelling and it is not on this project's machine. If you need what " <>
      "it does, say so rather than working around it."
  end

  defp describe(nil), do: "this agent"
  defp describe(kind), do: "a #{kind} agent"

  # A refusal with nowhere to go pushes an agent to work around it. Granting
  # `escalate_question` is not the fix: it writes a different table from the
  # questions product works with. See knowledge/tools, "Refusals".
  defp substitute_hint("escalate_question"),
    do: " Use `ask_question` instead — it reaches a human the same way."

  # Without a path, a coder that cannot retire a criterion deletes its spec.
  defp substitute_hint("retire_criterion"),
    do:
      " If a criterion is obsolete or wrong, don't delete its spec; file an app issue " <>
        "on the story (`create_issue`) naming the criterion and why; product retires " <>
        "or rewrites it."

  defp substitute_hint(_name), do: ""

  defp callback(tool) do
    fn args, state ->
      Progress.report({:call, tool.name})
      outcome = call(tool, arguments(state, args))
      Progress.report({:done, tool.name})

      case outcome do
        {:ok, value} ->
          {encoded, state} = Lua.encode!(state, value)
          {[encoded], state}

        # Stops the script. The tool never ran; `nil, err` here would let a
        # script carry on and report a conclusion drawn from a call that never
        # happened, which reads like a tool that found nothing.
        {:invalid_call, message} ->
          raise Lua.RuntimeException, rejected(tool, message)

        {:error, message} ->
          {encoded, state} = Lua.encode!(state, %{"tool" => tool.name, "message" => message})
          {[nil, encoded], state}
      end
    end
  end

  # Names the tool: a script makes several calls.
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

  # The same conversion the return path uses, applied recursively, so nested
  # arrays and objects reach validation as JSON shapes rather than Lua tuples.
  defp arguments(state, [table | _rest]) do
    case state |> Lua.decode!(table) |> LuaValue.from_lua() do
      %{} = args -> args
      # `{}` decodes as an empty list, and means no arguments.
      [] -> %{}
      other -> %{"_" => other}
    end
  end

  defp call(tool, args) do
    tool.invoke.(args)
  rescue
    exception ->
      # A tool crash is the tool's bug, so the script can carry on and report
      # it. Logged because nothing else would notice.
      Logger.error("[CodeMode] #{tool.name} crashed: #{Exception.message(exception)}")
      {:error, "#{tool.name} crashed: #{Exception.message(exception)}"}
  end
end
