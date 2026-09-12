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

  alias CodeMySpec.McpServers.{
    ArchitectureServer,
    ComponentsServer,
    IssuesServer,
    LocalServer,
    ScriptableTools
  }

  # Namespaces registered on their own server, outside the engineering
  # agent's surface entirely — a live checkout, not "presumably served by
  # another application" (b7a089fa's own guess): `Ga4Server`, `GoogleAdsServer`
  # and `GscServer` register every tool in these namespaces in this same repo.
  # Deliberately not checked here: "we don't want those available to the
  # agent yet — completely different scope outside of engineering" (John,
  # on this fix). Widening the checked-server list to include them was
  # rejected for that reason, so they are named here instead — the
  # allowlist the issue itself asked for once that decision is known.
  @out_of_scope_namespaces [
    CodeMySpec.McpServers.Ga4.Tools,
    CodeMySpec.McpServers.GoogleAds.Tools,
    CodeMySpec.McpServers.Gsc.Tools
  ]

  # Every module under `CodeMySpec.McpServers.*.Tools.*` that Anubis would
  # accept as a `component(...)` — i.e. every tool that *could* be
  # registered, not just the ones that are. This is what the original
  # spec's `everything` could never see: it was built only from the two
  # registries, so a module neither one had ever heard of was vacuously
  # absent from both sides of every assertion below.
  defp all_tool_modules do
    {:ok, modules} = :application.get_key(:code_my_spec, :modules)
    Enum.filter(modules, &tool_module?/1)
  end

  defp tool_module?(mod) do
    mcp_tool_namespace?(Module.split(mod)) and
      Code.ensure_loaded?(mod) and
      function_exported?(mod, :__mcp_component_type__, 0) and
      mod.__mcp_component_type__() == :tool
  end

  defp mcp_tool_namespace?(["CodeMySpec", "McpServers", _mid, "Tools" | _]), do: true
  defp mcp_tool_namespace?(_parts), do: false

  defp out_of_scope?(mod) do
    parts = Module.split(mod)

    Enum.any?(@out_of_scope_namespaces, fn namespace ->
      prefix = Module.split(namespace)
      Enum.take(parts, length(prefix)) == prefix
    end)
  end

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

      # b7a089fa: the case the two `then_` blocks above cannot see at all,
      # because both are built only from what the two registries already
      # know about. A tool module on neither one never enters `everything`
      # in the first place, so every assertion above passes vacuously for
      # it — exactly what let `Promotion.Tools.Promote` and `.PromoteSync`
      # ship registered nowhere, driven by fourteen spex files, unreachable
      # by any real agent.
      given_ "every tool module that could be registered at all", context do
        {:ok, Map.put(context, :all_tool_modules, all_tool_modules())}
      end

      when_ "checked against every server an engineering agent can reach", context do
        registered =
          [LocalServer, ScriptableTools, ComponentsServer, ArchitectureServer, IssuesServer]
          |> Enum.flat_map(& &1.__components__())
          |> MapSet.new(& &1.handler)

        {:ok, Map.put(context, :registered_anywhere, registered)}
      end

      then_ "every module is registered somewhere, or named as deliberately out of scope",
            context do
        orphaned =
          Enum.reject(context.all_tool_modules, fn mod ->
            MapSet.member?(context.registered_anywhere, mod) or out_of_scope?(mod)
          end)

        assert orphaned == [],
               "registered on none of LocalServer/ScriptableTools/ComponentsServer/" <>
                 "ArchitectureServer/IssuesServer, and not in @out_of_scope_namespaces — " <>
                 "no route reaches these at all: " <> inspect(orphaned)

        {:ok, context}
      end
    end
  end
end
