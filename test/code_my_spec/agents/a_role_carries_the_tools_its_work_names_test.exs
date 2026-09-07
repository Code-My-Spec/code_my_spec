defmodule CodeMySpec.Agents.ARoleCarriesTheToolsItsWorkNamesTest do
  @moduledoc """
  A task prompt must not name a tool the role that receives it cannot call.

  This is the sixth time in one session that an agent was told to do something
  with a tool it had not been given, and every time it cost a diversion to find,
  because from the outside it looks like the agent being stupid.

  The one that produced this test: `issues_triaged` is product's requirement.
  Product carries `triage_issues`, which hands back a prompt naming
  `accept_issue` and `dismiss_issue` five times — and carried neither. The agent
  read all four incoming issues, decided every one of them, and then had to tap
  out: "This product agent lacks the required accept/dismiss tools, so I
  requested tap-out for a role with triage authority." The work was done and
  could not be written down.

  ## What this checks, and what it deliberately does not

  Only backticked names that are **real tools** — anything else in a prompt is
  prose, and treating prose as a promise would make this list impossible to
  write. A tool named in a prompt for a role that does not carry it is the
  defect; a word in backticks that no tool answers to is a word in backticks.

  Direct-call-only tools are skipped too, and that is not a loophole. The loop's
  own tools — `evaluate_task`, `start_task`, `tap_out`, `ask_user_question`,
  `get_next_requirement` — are in `Catalog.excluded()`: callable as tools, never
  from a script, so `ToolSets` does not gate them and every agent has them.
  Without this the check reports all five against every role and says nothing.

  `:main` carries everything (`for_role/1` answers `nil`), so it cannot fail
  this and is skipped rather than special-cased into a pass.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.ToolSets
  alias CodeMySpec.CodeMode.Catalog
  alias CodeMySpec.McpServers.LocalServer
  alias CodeMySpec.McpServers.ScriptableTools
  alias CodeMySpec.Requirements.RequirementDefinitionData, as: Definitions

  # Every tool this server answers to, from the server itself rather than a
  # list — a hand-written catalogue would go stale the day a tool is added, and
  # the staleness would read as "this name is not a tool" and pass.
  # Scoped tools only: what `ToolSets` grants and withholds. A direct-call tool
  # is not gated by it, so naming one in a prompt is never the defect.
  defp scoped_tool_names do
    (LocalServer.__components__() ++ ScriptableTools.__components__())
    |> MapSet.new(& &1.name)
    |> MapSet.difference(MapSet.new(Catalog.excluded()))
  end

  # Every graph the definitions module publishes. Component graphs are reached
  # by type through the registry, which is the same list `all_graphs/0` folds
  # privately — enumerated here rather than reaching for that, so a graph added
  # without a `graph_for_type` entry is visibly not covered instead of silently
  # not covered.
  @component_types ~w(context coordination_context live_context controller schema
                      behaviour json liveview liveview_component other)

  defp definitions do
    component =
      Enum.flat_map(@component_types, fn type ->
        CodeMySpec.Requirements.Registry.get_requirements_for_type(type)
      end)

    Definitions.project_requirements() ++ Definitions.story_requirements() ++ component
  end

  # The task module a requirement is satisfied by, as source. Nothing is loaded
  # or executed — the prompt is built from a scope this test does not have, and
  # the names are in the source either way.
  defp source_of(module) do
    case module.__info__(:compile)[:source] do
      nil -> nil
      path -> path |> to_string() |> File.read() |> case(do: ({:ok, s} -> s; _ -> nil))
    end
  end

  defp tools_named_in(source, catalogue) do
    ~r/`([a-z][a-z0-9_]{2,})`/
    |> Regex.scan(source)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(catalogue, &1))
  end

  # One unsettled pair, named rather than hidden.
  #
  # `issues_resolved` and `story_issues_resolved` are coding's, satisfied by
  # `FixIssues` and `FixStoryIssues`, whose prompts say to call `resolve_issue`.
  # `ToolSets` withholds it from coding on a stated rule: "a coding agent that
  # can resolve the issue it was given is grading its own work."
  #
  # Both cannot be right, and which one gives is a design decision rather than a
  # gap to close by adding a tool — either coding records its own fixes and QA
  # re-tests, or resolving belongs to whoever verifies and the requirement is
  # not coding's. Listed here so the check stays useful for everything else and
  # this stays visible instead of being quietly granted.
  @unsettled [
    "issues_resolved (coding) → CodeMySpec.AgentTasks.FixIssues names `resolve_issue`",
    "story_issues_resolved (coding) → CodeMySpec.AgentTasks.FixStoryIssues names `resolve_issue`"
  ]

  test "every tool a requirement's task names is one its role carries" do
    catalogue = scoped_tool_names()

    gaps =
      for definition <- definitions(),
          role = definition.role,
          not is_nil(role),
          role != :main,
          module = definition.satisfied_by,
          not is_nil(module),
          carried = ToolSets.for_role(role),
          is_list(carried),
          source = source_of(module),
          not is_nil(source),
          tool <- tools_named_in(source, catalogue),
          tool not in carried do
        "#{definition.name} (#{role}) → #{inspect(module)} names `#{tool}`"
      end
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reject(&(&1 in @unsettled))

    assert gaps == [],
           """
           A requirement's task tells its agent to call a tool that role does not have.

           #{Enum.map_join(gaps, "\n", &("  " <> &1))}

           Either add the tool to that role in `CodeMySpec.Agents.ToolSets`, or stop
           naming it in the prompt. An agent that is told to do a thing it cannot do
           has no way to say so except to tap out, and from the outside that looks
           like the agent failing rather than the instruction being impossible.
           """
  end

  # The specific pair this was written for, pinned by name. The general check
  # above would go quiet if either prompt stopped naming them; this says they
  # are product's on purpose.
  test "product can record a triage decision" do
    carried = ToolSets.for_role(:product)

    assert "accept_issue" in carried
    assert "dismiss_issue" in carried
  end

  # And the line the neighbouring comment draws: deciding whether an issue is
  # real is product's, declaring it fixed is not.
  test "neither product nor coding declares an issue fixed" do
    refute "resolve_issue" in ToolSets.for_role(:product)
    refute "resolve_issue" in ToolSets.for_role(:coding)
  end

  # An exception that stopped being one is worse than no list: it reads as a
  # decision somebody made and is really a line nobody deleted.
  test "the unsettled list still describes something unsettled" do
    catalogue = scoped_tool_names()

    live =
      for definition <- definitions(),
          role = definition.role,
          not is_nil(role),
          role != :main,
          module = definition.satisfied_by,
          not is_nil(module),
          carried = ToolSets.for_role(role),
          is_list(carried),
          source = source_of(module),
          not is_nil(source),
          tool <- tools_named_in(source, catalogue),
          tool not in carried,
          do: "#{definition.name} (#{role}) → #{inspect(module)} names `#{tool}`"

    stale = @unsettled -- Enum.uniq(live)

    assert stale == [],
           "these are listed as unsettled and no longer happen — delete them:\n" <>
             Enum.map_join(stale, "\n", &("  " <> &1))
  end
end
