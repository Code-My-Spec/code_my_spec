defmodule CodeMySpec.Requirements.PlainLanguageMatchesGraphTest do
  @moduledoc """
  The timeline's vocabulary and the graph's must be the same words.

  `ProjectTimeline` draws one step per name in `PlainLanguage.order/0` and marks
  it done by looking that name up among the satisfied nodes of
  `Requirements.cached_all/1`. Nothing checked that the two lists agree, and
  they drifted: `PlainLanguage` described `story_work` while the graph produces
  `work_dispatched`.

  Neither half of that drift announces itself.

  A name the timeline describes and the graph never emits renders a step that
  can never be satisfied. It sits grey through a project's whole life, and it
  looks exactly like work nobody has got to yet — John, reading his own
  timeline: *"I know a bunch of downstream requirements are done and I don't
  think this is representing that."*

  A name the graph emits and the timeline does not describe is worse in the
  other direction: the step is simply absent, and the strip looks complete
  without it. That is the failure the whole "every requirement is on the line"
  design exists to prevent — a cut list cannot answer a question about a step it
  left out, and neither can a list that lost one by accident.

  So this compares the two directly, through the same call the timeline makes.
  Not against `RequirementDefinitionData.project_requirements/0`: the graph is
  assembled per scope, and testing the source rather than the surface would miss
  anything the assembly adds, drops or renames on the way through.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.ProjectsFixtures

  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.PlainLanguage

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user, %{name: "Vocabulary #{System.unique_integer()}"})
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope, %{name: "Vocabulary project"})

    %{scope: %{scope | active_project_id: project.id, active_project: project}}
  end

  test "every step the timeline can draw is a node the graph produces", %{scope: scope} do
    {nodes, _computed_at} = Requirements.cached_all(scope)

    graph_names = nodes |> Enum.map(& &1.name) |> MapSet.new()
    described = PlainLanguage.order() |> MapSet.new()

    phantom = MapSet.difference(described, graph_names)

    assert MapSet.size(phantom) == 0,
           "PlainLanguage describes #{inspect(MapSet.to_list(phantom))}, which the project " <>
             "graph never produces. The timeline draws a step for each of those and looks " <>
             "it up among the satisfied nodes by name, so it can never match — the step " <>
             "stays grey for the life of the project and reads as work nobody has started."
  end

  test "every node the graph produces has words the timeline can draw", %{scope: scope} do
    {nodes, _computed_at} = Requirements.cached_all(scope)

    graph_names = nodes |> Enum.map(& &1.name) |> MapSet.new()
    described = PlainLanguage.order() |> MapSet.new()

    undescribed = MapSet.difference(graph_names, described)

    assert MapSet.size(undescribed) == 0,
           "the project graph produces #{inspect(MapSet.to_list(undescribed))}, which " <>
             "PlainLanguage does not describe. Those steps are absent from the timeline " <>
             "and it looks complete without them — which is the one thing putting every " <>
             "requirement on the line was meant to rule out. Add a title, an abbreviation " <>
             "and a phase for each."
  end

  test "every described step carries the three things the strip renders" do
    for name <- PlainLanguage.order() do
      meaning = PlainLanguage.fetch(name)

      assert meaning, "#{name} is in the order but `fetch/1` returns nothing for it"

      assert is_binary(meaning.title) and meaning.title != "",
             "#{name} has no title, so its step has no name on hover or for a screen reader"

      assert is_binary(meaning.abbrev) and meaning.abbrev != "",
             "#{name} has no abbreviation, so the pill renders empty when it is the " <>
               "current step — the one place the strip spends words"

      assert meaning.phase in Enum.map(PlainLanguage.phases(), &elem(&1, 0)),
             "#{name} names phase #{inspect(meaning.phase)}, which is not one of the " <>
               "phases — its step would be dropped from the strip entirely"
    end
  end
end
