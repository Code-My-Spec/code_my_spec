defmodule CodeMySpecSpex.Story1033.Criterion3002Spex do
  @moduledoc """
  Story 1033 — I connect with a short tool list
  Criterion 3002 — No tool falls through the gap between the two surfaces

  The failure this split could most easily produce and the least likely to be
  noticed: a tool on neither list is reachable by no route at all, and nothing
  says so.

  The rule the story ends on is the second half — every tool a script may not
  call has to stay advertised, or excluding it makes it unreachable rather than
  direct-call-only.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.McpServers.CodeMode, as: CodeModeLayer
  alias CodeMySpec.McpServers.{LocalServer, ScriptableTools}

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I connect with a short tool list" do
    scenario "No tool falls through the gap between the two surfaces" do
      given_ "the two surfaces an agent has", context do
        advertised = MapSet.new(LocalServer.__components__(), & &1.name)
        scriptable = MapSet.new(ScriptableTools.__components__(), & &1.name)

        {:ok, context |> Map.put(:advertised, advertised) |> Map.put(:scriptable, scriptable)}
      end

      when_ "every registered tool is checked against both", context do
        everything = MapSet.union(context.advertised, context.scriptable)

        {:ok, Map.put(context, :everything, everything)}
      end

      then_ "every tool appears in one of them", context do
        assert MapSet.size(context.everything) ==
                 MapSet.size(context.advertised) + MapSet.size(context.scriptable),
               "a tool is on both lists: " <>
                 inspect(
                   MapSet.intersection(context.advertised, context.scriptable)
                   |> MapSet.to_list()
                 )

        assert MapSet.size(context.everything) > 100
        {:ok, context}
      end

      then_ "and every tool a script cannot call is advertised", context do
        # Asked of the real catalog rather than of the excluded list: Boundary
        # will not let a spex reach into `CodeMySpec`, and asking the surface
        # what it actually binds is the better question anyway — a name could
        # drop out of the catalog for a reason nobody wrote down.
        scriptable_now = context.scope |> CodeModeLayer.catalog() |> Map.keys() |> MapSet.new()

        unreachable =
          context.everything
          |> MapSet.difference(scriptable_now)
          |> Enum.reject(&(&1 in context.advertised))

        assert unreachable == [],
               "these can be neither called directly nor scripted, so no route reaches " <>
                 "them at all: " <> inspect(unreachable)

        {:ok, context}
      end
    end
  end
end
