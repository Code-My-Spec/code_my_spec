defmodule CodeMySpec.Validation.TheCountAgreesWithTheListTest do
  @moduledoc """
  The menu counts the work `get_next_requirement` will actually hand out.

  Watched on 2026-09-07, once every six seconds: the stop menu refused with
  "Next: 27 requirements — call `get_next_requirement`", the agent called it,
  and the tool answered "All requirements satisfied". The agent had nothing to
  do and no way to say so, and the menu kept it there.

  Two sources for one sentence. The tool computes the graph; the menu counted
  `requirements` rows, and rows are only written when something computes. So the
  menu could advertise work that had already been done for as long as it took
  the next recompute to catch up.

  The menu read rows to avoid a recompute inside the channel process, on a
  hazard that no longer exists — the graph is database-only now. So both halves
  of the sentence come from `next_actionable/1`, and the property under test is
  that they cannot disagree.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.Node
  alias CodeMySpec.Requirements.NodeRepository
  alias CodeMySpec.Requirements.Projection
  alias CodeMySpec.Requirements.Registry
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Validation.Menu

  defp agent(role), do: %Agent{role: role, continuous: true, tasks: []}

  # A row the computed graph does not contain: `spec_file` for a component with
  # no story behind it. This is what a stale read model looks like — a row left
  # by an older compute, describing work that is no longer anybody's.
  #
  # Written at `Projection.vantage/1` because the row count is per checkout, so
  # a row at another vantage would be skipped and prove nothing.
  defp stale_row(scope) do
    component = component_fixture(scope)

    Repo.insert!(
      Node.changeset(%Node{}, %{
        name: "spec_file",
        description: "left behind by an older compute",
        satisfied: false,
        component_id: component.id,
        working_copy_id: Projection.vantage(scope)
      })
    )

    scope
  end

  defp actionable_for(scope, role) do
    names = Registry.requirement_names_for_role(role)

    scope
    |> RequirementGraph.next_actionable()
    |> Enum.filter(&(&1.name in names))
  end

  # The control: the row is exactly the kind the old count counted. Without
  # this, the test below could pass against a row nothing ever looked at.
  test "the stale row is one the row count does count" do
    scope = stale_row(full_scope_fixture())

    assert NodeRepository.actionable_count(scope, :coding) == 1
  end

  test "a row the graph does not contain is not advertised as work" do
    scope = stale_row(full_scope_fixture())

    assert actionable_for(scope, :coding) == []
    assert Requirements.actionable_count(scope, :coding) == 0
  end

  test "the menu does not send an agent to fetch work the tool will not hand it" do
    scope = stale_row(full_scope_fixture())

    refute Menu.render(scope, true, :coding, agent(:coding)) =~ "`get_next_requirement`"
  end

  # The other direction, so the fix is not "always answer zero": a role with
  # real work is still sent to fetch it, and the number matches the list.
  test "a role with work is still sent to it, by the same number" do
    scope = full_scope_fixture()

    [_ | _] = actionable = actionable_for(scope, :product)

    assert Requirements.actionable_count(scope, :product) == length(actionable)
    assert Menu.render(scope, true, :product, agent(:product)) =~ "`get_next_requirement`"
  end

  # No role means no narrowing — a Claude Code session driving by hand sees the
  # whole graph, which is what it saw before roles existed.
  test "no role counts the whole graph" do
    scope = full_scope_fixture()

    assert Requirements.actionable_count(scope, nil) ==
             length(RequirementGraph.next_actionable(scope))
  end

  test "a scope with no project counts nothing" do
    scope = %{full_scope_fixture() | active_project_id: nil}

    assert Requirements.actionable_count(scope, :coding) == 0
  end
end
