defmodule CodeMySpec.Agents.ToolIndex do
  @moduledoc """
  Every tool this agent can reach, by name, and nothing else.

  Names only — no descriptions, no schemas. An agent already gets full schemas
  for the tools it carries, and `tool_docs` answers for the rest on demand;
  what it cannot otherwise learn is that the rest exist. A couple of kilobytes
  per turn, cheaper than one wasted turn.

  See knowledge/agents/coordination, "The tool index".

  ## Three groups, because reaching them differs

  Carried tools are called directly. Scriptable tools are called from inside
  `run_script`. Browser tools are called from inside `run_browser_script` and
  belong to the machine rather than to us. An agent that knows a name but calls
  it the wrong way is no better off, so the grouping is the instruction.
  """

  alias CodeMySpec.Agents.{Agent, RoleProfile}
  alias CodeMySpec.CodeMode.Catalog

  @typedoc """
  The components the MCP layer registers: `direct` from `LocalServer`,
  `scriptable` from `ScriptableTools`.

  Handed in, for the reason `CodeMode.Catalog` gives: `McpServers` depends on
  `Agents`, so reading the servers from here points the arrow up.
  `McpServers.ToolRegistry.registry/0` builds it.
  """
  @type registry :: %{
          required(:direct) => [map()],
          required(:scriptable) => [map()],
          optional(:tombstoned) => [String.t()]
        }

  @doc """
  The index for this agent, or `nil` when there is nothing to say.

  `nil` rather than an empty heading. `machine_tools` comes from the working
  copy the agent runs on; a machine with no browser contributes no section.
  """
  @spec for(Agent.t(), registry(), [String.t()]) :: String.t() | nil
  def for(%Agent{} = agent, registry, machine_tools \\ []) do
    [
      section(direct_heading(), carried(registry)),
      section(scriptable_heading(), reach(agent, registry)["scriptable"]),
      section(browser_heading(), Enum.sort(machine_tools || []))
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      sections -> Enum.join([preamble() | sections], "\n\n")
    end
  end

  defp preamble do
    """
    ## Tools you can reach

    Names only. `tool_docs` gives arguments for any of them.

    **The three lists are reached three different ways, and using the wrong one
    fails.** A name below is a tool you can reach; how you reach it depends on
    which list it is in. A name *absent* from all three is a tool you cannot
    reach at all — report that rather than working around it.
    """
    |> String.trim()
  end

  defp section(_heading, []), do: nil
  defp section(_heading, nil), do: nil

  defp section(heading, names), do: "**#{heading}:** " <> Enum.join(names, ", ")

  # Headings name the route, not the wire format: how a call is physically made
  # differs per provider and lives in `ProviderBrief`.
  defp direct_heading, do: "Called directly"

  defp scriptable_heading, do: "Called from inside `run_script`"

  defp browser_heading, do: "Called from inside `run_browser_script`"

  # The direct section is what the direct server exposes, less what the engine
  # does not carry; the same for every agent, never the `tools` column (that
  # governs what a script may call).
  #
  # Direct tools an in-BEAM agent does not carry. `promote_sync` holds a call
  # open for a build where `promote` messages the result back; `health` was
  # never given a harness module.
  @not_carried ~w(health promote_sync)

  @doc """
  The direct tools an in-BEAM agent carries: `LocalServer`'s, less
  `@not_carried`. `CmsHarness.Agents.Engine.tools/1` builds from this, so the
  index cannot name a tool the engine answers `Unknown tool` for.
  """
  @spec carried(registry()) :: [String.t()]
  def carried(%{direct: direct} = registry) do
    direct
    |> Enum.map(& &1.name)
    |> Enum.reject(&(&1 in @not_carried or &1 in tombstoned(registry)))
    |> Enum.sort()
  end

  @doc """
  The `carried/1` tools as the harness builds them: name, description and
  input schema, read from the registration the server lists, so the engine's
  copy of a tool cannot drift from the one every other client sees.
  """
  @spec carried_definitions(registry()) :: [map()]
  def carried_definitions(%{direct: direct} = registry) do
    names = carried(registry)

    for %{name: name} = tool <- Enum.sort_by(direct, & &1.name), name in names do
      %{
        "name" => name,
        "description" => tool.description,
        "input_schema" => tool.input_schema
      }
    end
  end

  @doc """
  What this agent can reach from `run_script`, and what exists that it cannot.

  The data the index's scriptable section renders from, sent to the harness so a
  wrong call is answered from the same grant. `holders` names roles that carry
  each ungranted tool; `main` carries every one.
  """
  @spec reach(Agent.t(), registry()) :: %{String.t() => term()}
  def reach(%Agent{tools: allowed}, %{scriptable: all} = registry) do
    # A removed tool stays callable for a stale session but is never advertised.
    registered = Enum.reject(all, &(&1.name in tombstoned(registry)))
    not_granted = Catalog.out_of_scope(registered, allowed)

    %{
      "scriptable" => scriptable(registered, allowed),
      "not_granted" => not_granted,
      "holders" => Map.new(not_granted, &{&1, holders(&1)})
    }
  end

  defp tombstoned(registry), do: Map.get(registry, :tombstoned, [])

  # Scoped roles first, then the roles that carry every tool.
  defp holders(name) do
    {all, scoped} = Enum.split_with(RoleProfile.all(), &(&1.tools == :all))

    (Enum.filter(scoped, &RoleProfile.carries?(&1.role, name)) ++ all)
    |> Enum.map(&to_string(&1.role))
  end

  # `Catalog.from/3` and `Catalog.names/1` are total over a well-formed
  # component list; a malformed registration should be loud, not an empty index.
  defp scriptable(registered, allowed) do
    registered
    |> Catalog.from(fn _tool -> fn _args -> {:error, :index_only} end end, allowed)
    |> Catalog.names()
  end
end
