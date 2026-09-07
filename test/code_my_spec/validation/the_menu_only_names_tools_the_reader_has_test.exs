defmodule CodeMySpec.Validation.TheMenuOnlyNamesToolsTheReaderHasTest do
  @moduledoc """
  The refusal an agent reads most must not name a tool it cannot call.

  `ARoleCarriesTheToolsItsWorkNamesTest` checks task prompts. This checks the
  other instruction surface, and the busier one: every stop produces a menu, and
  a menu that says "call `list_problems`" to a role without it spends the
  agent's turn teaching it that the advice was impossible.

  Driven through `Menu.render/4` rather than by reading the source, because
  which tools the menu names depends on which classes are live and on the role —
  `@problem_roles` is exactly why `list_problems` in the source is not a defect
  for QA. Scanning would report it; rendering does not.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.ProblemsFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.ToolSets
  alias CodeMySpec.CodeMode.Catalog
  alias CodeMySpec.McpServers.LocalServer
  alias CodeMySpec.McpServers.ScriptableTools
  alias CodeMySpec.Validation.Menu

  @roles [:product, :coding, :qa]

  defp scoped_tool_names do
    (LocalServer.__components__() ++ ScriptableTools.__components__())
    |> MapSet.new(& &1.name)
    |> MapSet.difference(MapSet.new(Catalog.excluded()))
  end

  defp tools_named_in(text, catalogue) do
    ~r/`([a-z][a-z0-9_]{2,})`/
    |> Regex.scan(text)
    |> Enum.map(fn [_, name] -> name end)
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(catalogue, &1))
  end

  defp agent(role), do: %Agent{role: role, continuous: true, tasks: []}

  defp unreadable(menu, role, catalogue) do
    carried = ToolSets.for_role(role)

    menu
    |> tools_named_in(catalogue)
    |> Enum.reject(&(&1 in carried))
    |> Enum.map(&"#{role}: #{&1}")
  end

  setup do
    scope = full_scope_fixture()
    _component = component_fixture(scope)
    %{scope: scope, catalogue: scoped_tool_names()}
  end

  test "with work waiting, every tool the menu names is one that role carries",
       %{scope: scope, catalogue: catalogue} do
    gaps =
      Enum.flat_map(@roles, fn role ->
        scope
        |> Menu.render(true, role, agent(role))
        |> unreadable(role, catalogue)
      end)

    assert gaps == [], """
    The stop menu told an agent to call a tool its role does not carry:

    #{Enum.map_join(gaps, "\n", &("  " <> &1))}

    Every stop renders this, so the cost is paid on every turn — the agent reads
    advice it cannot take and has no way to say so except to try and be refused.
    """
  end

  # The problems class is the one with a role gate on it, so it is the one worth
  # rendering deliberately rather than hoping the fixture makes it live.
  test "a broken tree names list_problems only to roles that carry it",
       %{scope: scope, catalogue: catalogue} do
    problem_fixture(scope, %{severity: :error, source: "compiler"})

    gaps =
      Enum.flat_map(@roles, fn role ->
        scope
        |> Menu.render(true, role, agent(role))
        |> unreadable(role, catalogue)
      end)

    assert gaps == [], """
    With errors on the tree, the menu named a tool the role cannot call:

    #{Enum.map_join(gaps, "\n", &("  " <> &1))}
    """
  end

  # And an agent holding a task, which displaces the requirements directive and
  # renders a different sentence.
  test "an open task's directive names nothing the holder lacks",
       %{scope: scope, catalogue: catalogue} do
    task = %CodeMySpec.Sessions.Task{
      id: "5c3e2f10-0c4a-4b1e-9f0d-7a6b5c4d3e2f",
      status: :active,
      requirement_name: "issues_triaged",
      story_id: 904
    }

    gaps =
      Enum.flat_map(@roles, fn role ->
        scope
        |> Menu.render(true, role, %Agent{role: role, continuous: true, tasks: [task]})
        |> unreadable(role, catalogue)
      end)

    assert gaps == [], """
    The open-task directive named a tool the holder cannot call:

    #{Enum.map_join(gaps, "\n", &("  " <> &1))}
    """
  end
end
