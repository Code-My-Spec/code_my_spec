defmodule CodeMySpec.Requirements.TheJourneyChainEndsAtExecuteTest do
  @moduledoc """
  `qa_journey_wallaby` is gone (issue a621b5dd). It was offered to QA whatever
  the project's test stack, and a project that rejects Wallaby claimed,
  cancelled and was re-offered it in a loop. Journeys are codified as LiveView
  tests in the same session as `qa_journey_execute`, which ends the chain.

  The release still waits on `qa_journey_execute`'s artifact (criteria 540, 759).
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.AgentTasks.Release
  alias CodeMySpec.Environments
  alias CodeMySpec.Paths
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "QA is never offered qa_journey_wallaby" do
    refute "qa_journey_wallaby" in RequirementDefinitionData.requirement_names_for_role(:qa)

    refute Enum.any?(
             RequirementDefinitionData.project_graph(),
             &(&1.name == "qa_journey_wallaby")
           )
  end

  test "qa_journey_execute ends the project chain, after qa_journey_plan" do
    graph = RequirementDefinitionData.project_graph()
    by_name = Map.new(graph, &{&1.name, &1})
    execute = Map.fetch!(by_name, "qa_journey_execute")
    plan = Map.fetch!(by_name, "qa_journey_plan")

    assert execute.prerequisites == [plan.id]
    refute Enum.any?(graph, &(execute.id in &1.prerequisites))

    ids = MapSet.new(graph, & &1.id)

    for definition <- graph, prereq <- definition.prerequisites do
      assert prereq in ids, "#{definition.name} waits on missing id #{prereq}"
    end
  end

  test "the release waits on qa_journey_execute's artifact" do
    execute =
      Enum.find(RequirementDefinitionData.project_graph(), &(&1.name == "qa_journey_execute"))

    assert execute.config.path == Paths.qa_journey_result()
  end

  describe "a project with every QA artifact but journey tests" do
    setup ctx do
      ctx = FullSatisfactionFixtures.apply_without_release(ctx)
      :ok = Fixtures.settle_graph(ctx.scope)
      ctx
    end

    test "completes QA's journey chain", ctx do
      assert Environments.glob(ctx.scope.environment, "test/journeys/*_test.exs") in [[], nil]

      for name <- ~w(qa_journey_plan qa_journey_execute) do
        assert Fixtures.requirement_satisfied?(ctx.scope, name, :project, ctx.project.id),
               "#{name} unsatisfied"
      end

      names = ctx.scope |> CodeMySpec.Requirements.compute_all() |> Enum.map(&to_string(&1.name))
      refute "qa_journey_wallaby" in names

      refute Enum.any?(
               Fixtures.actionable_names(ctx.scope, :qa),
               &String.starts_with?(&1, "qa_journey")
             )
    end

    test "the release is refused only while the journey result is missing", ctx do
      {:ok, ready} = Release.command(ctx.scope, %{})
      refute ready =~ "the user journeys come first"

      :ok = Environments.delete_file(ctx.scope.environment, Paths.qa_journey_result())
      {:ok, refused} = Release.command(ctx.scope, %{})
      assert refused =~ "the user journeys come first"
    end
  end
end
