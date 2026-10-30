defmodule CodeMySpec.Requirements.DeployWaitsForDevopsSetupTest do
  @moduledoc """
  `deploy` is not offered while the project's devops setup is missing steps
  for UAT, and the node says which (a86c85dd).
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Configurations
  alias CodeMySpec.Provisioning
  alias CodeMySpec.ProvisioningPlan.StepRepository
  alias CodeMySpec.Requirements.Handlers
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Requirements.RequirementGraph

  setup do
    scope = full_scope_fixture()
    story = story_fixture(scope, %{ready_for_dev: true})
    %{scope: scope, story: story}
  end

  describe "with devops on and no environment rows" do
    setup %{scope: scope} do
      {:ok, _} = Configurations.update(scope, %{devops: :uat})
      :ok
    end

    test "a graph load writes no rows and holds deploy as not started", ctx do
      {:ok, _} = Preloader.load(ctx.scope)
      deploy = deploy_node(ctx.scope, ctx.story)
      {:ok, [], sweeps} = Handlers.apply_event(ctx.scope, "devops_setup_changed", %{})

      assert Provisioning.existing_environments(ctx.scope) == []
      assert StepRepository.list(ctx.scope) == []

      refute deploy.satisfied
      assert reason(deploy) == "devops setup not started for uat"
      assert offered(ctx.scope, deploy) == []

      sweep = Enum.find(sweeps, &(&1.name == "deploy"))
      assert sweep.default_details["reason"] == "devops setup not started for uat"
      assert sweep.default_details["waiting_on"] == "devops_setup"
    end
  end

  describe "with devops on" do
    setup %{scope: scope} do
      {:ok, _} = Configurations.update(scope, %{devops: :uat})
      # Seeded here, because a graph read never seeds them.
      _ = Provisioning.environments(scope)
      :ok
    end

    test "a missing UAT setup step keeps deploy from being offered, and names the step", ctx do
      deploy = deploy_node(ctx.scope, ctx.story)

      refute deploy.satisfied
      assert reason(deploy) =~ "devops setup incomplete for uat"
      assert reason(deploy) =~ "uat/deploy"
      assert offered(ctx.scope, deploy) == []
    end

    test "deploy is offered once UAT setup is complete", ctx do
      complete_setup(ctx.scope)

      deploy = deploy_node(ctx.scope, ctx.story)

      refute deploy.satisfied
      refute reason(deploy) =~ "setup incomplete"
      assert offered(ctx.scope, deploy) == [deploy]
    end

    test "a missing prod step does not hold a UAT deploy", ctx do
      {:ok, _} = Configurations.update(ctx.scope, %{devops: :prod})
      complete_setup(ctx.scope, &(&1.environment in [nil, "uat"]))

      deploy = deploy_node(ctx.scope, ctx.story)

      assert offered(ctx.scope, deploy) == [deploy]
    end

    test "the event path settles deploy from the same answer", ctx do
      {:ok, [], sweeps} = Handlers.apply_event(ctx.scope, "devops_setup_changed", %{})
      sweep = Enum.find(sweeps, &(&1.name == "deploy"))

      assert sweep.default_details["waiting_on"] == "devops_setup"
      assert sweep.default_details["reason"] =~ "uat/deploy"

      complete_setup(ctx.scope)
      {:ok, [], sweeps} = Handlers.apply_event(ctx.scope, "devops_setup_changed", %{})
      sweep = Enum.find(sweeps, &(&1.name == "deploy"))

      refute Map.has_key?(sweep.default_details, "waiting_on")
    end
  end

  test "with devops off there is no deploy node at all", ctx do
    {nodes, _edges, _actionable} = RequirementGraph.compute_graph_with_actionable(ctx.scope)

    refute Enum.any?(nodes, &(&1.name == "deploy"))
  end

  defp deploy_node(scope, story) do
    {nodes, _edges, _actionable} = RequirementGraph.compute_graph_with_actionable(scope)

    Enum.find(
      nodes,
      &(&1.entity_type == "story" and &1.entity_id == story.id and &1.name == "deploy")
    )
  end

  # The node on its own, with no edges, so only its own verdict decides.
  defp offered(scope, deploy) do
    {:ok, ctx} = Preloader.load(scope)
    RequirementGraph.actionable_for_role_from([deploy], [], ctx, :main)
  end

  defp reason(node), do: Requirement.normalize_details(node.details)["reason"] || ""

  defp complete_setup(scope, keep? \\ fn _ -> true end) do
    scope
    |> Provisioning.plan(Provisioning.setup_options(scope))
    |> Enum.filter(keep?)
    |> Enum.each(
      &StepRepository.upsert(scope, &1.key, &1.environment, %{state: :done, position: &1.position})
    )
  end
end
