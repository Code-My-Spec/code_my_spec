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

  @printed :code_mode_printed

  @doc "Binds every tool in `catalog`, plus a capturing `print`."
  @spec install(Lua.t(), Catalog.t()) :: Lua.t()
  def install(lua, catalog) do
    lua
    |> Lua.put_private(@printed, [])
    |> capture_print()
    |> bind_tools(catalog)
  end

  @doc "What the script printed, in order."
  @spec printed(Lua.t()) :: [String.t()]
  def printed(lua), do: Lua.get_private!(lua, @printed)

  # `print` writes to real stdout otherwise, which on a server means a script's
  # debugging lands in the server log and never reaches the agent that wrote it.
  defp capture_print(lua) do
    Lua.set!(lua, [:print], fn args, state ->
      line = Enum.map_join(args, "\t", &render/1)
      {[], Lua.put_private(state, @printed, Lua.get_private!(state, @printed) ++ [line])}
    end)
  end

  defp render(value) when is_binary(value), do: value
  defp render(value) when is_boolean(value), do: to_string(value)
  defp render(value) when is_float(value), do: value |> whole() |> to_string()
  defp render(value) when is_number(value), do: to_string(value)
  defp render(nil), do: "nil"
  defp render(value), do: inspect(value)

  defp bind_tools(lua, catalog) do
    Enum.reduce(catalog, lua, fn {name, tool}, acc ->
      Lua.set!(acc, [String.to_atom(name)], callback(tool))
    end)
  end

  defp callback(tool) do
    fn args, state ->
      case call(tool, arguments(state, args)) do
        {:ok, value} ->
          {encoded, state} = Lua.encode!(state, value)
          {[encoded], state}

        {:error, message} ->
          {encoded, state} = Lua.encode!(state, %{"tool" => tool.name, "message" => message})
          {[nil, encoded], state}
      end
    end
  end

  # A tool called with no arguments is the common case for the listing tools,
  # and Lua spells that `list_stories()` rather than `list_stories({})`.
  defp arguments(_state, []), do: %{}

  defp arguments(state, [table | _rest]) do
    state |> Lua.decode!(table) |> Map.new() |> normalise()
  end

  defp normalise(args) do
    Map.new(args, fn
      {key, value} when is_float(value) -> {to_string(key), whole(value)}
      {key, value} -> {to_string(key), value}
    end)
  end

  # Lua has one number type, so every integer arrives as a float and a tool
  # expecting an integer id rejects `970.0`. Only exact integers are converted;
  # a genuine fraction is left alone rather than quietly truncated.
  defp whole(value) when is_float(value) do
    truncated = trunc(value)

    case truncated == value do
      true -> truncated
      false -> value
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
