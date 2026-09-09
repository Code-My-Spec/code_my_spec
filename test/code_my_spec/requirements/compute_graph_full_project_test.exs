defmodule CodeMySpec.Requirements.ComputeGraphFullProjectTest do
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.{ComponentSync, FileSync}
  alias CodeMySpec.Integration.WorkflowHelpers
  alias CodeMySpec.Projects
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Stories
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "compute_graph/1 — full project with stories, contexts, and dependencies" do
    test "produces %Requirement{} structs, not bare maps" do
      {scope, _tmp_dir} = setup_full_project()

      {nodes, _edges} = RequirementGraph.compute_graph(scope)

      assert nodes != []

      Enum.each(nodes, fn node ->
        assert %Requirement{} = node
      end)
    end

    test "nodes span all three entity types" do
      {scope, _tmp_dir} = setup_full_project()

      {nodes, _edges} = RequirementGraph.compute_graph(scope)
      types = nodes |> Enum.map(& &1.entity_type) |> Enum.uniq() |> Enum.sort()

      assert types == ["component", "project", "story"]
    end

    test "no rollup nodes (component_complete, all_stories_complete) in output" do
      {scope, _tmp_dir} = setup_full_project()

      {nodes, _edges} = RequirementGraph.compute_graph(scope)
      names = MapSet.new(nodes, & &1.name)

      refute MapSet.member?(names, "component_complete")
      refute MapSet.member?(names, "all_stories_complete")
    end

    test "edges include cross-entity dependencies" do
      {scope, _tmp_dir} = setup_full_project()

      {_nodes, edges} = RequirementGraph.compute_graph(scope)

      edge_types =
        Enum.map(edges, fn e ->
          {elem(e.from, 0), elem(e.to, 0)}
        end)
        |> Enum.uniq()

      # Same-entity edges exist (project prereqs)
      assert {"project", "project"} in edge_types

      # Cross-entity: story → component (bdd_specs_exist → component first req)
      assert {"story", "component"} in edge_types

      # Cross-entity: component → story (component terminal → qa_complete)
      assert {"component", "story"} in edge_types

      # Cross-entity: story → project (qa_complete → qa_journey_plan)
      assert {"story", "project"} in edge_types
    end

    test "component nodes include context, its children, and dependencies" do
      {scope, _tmp_dir} = setup_full_project()

      all_components = Components.list_components(scope)
      module_names = Enum.map(all_components, & &1.module_name) |> Enum.sort()
      assert "MyApp.Accounts" in module_names
      assert "MyApp.Accounts.User" in module_names
      assert "MyApp.Accounts.Repo" in module_names

      {nodes, _edges} = RequirementGraph.compute_graph(scope)

      component_names =
        nodes
        |> Enum.filter(&(&1.entity_type == "component"))
        |> Enum.map(& &1.entity_name)
        |> Enum.uniq()
        |> Enum.sort()

      assert "MyApp.Accounts" in component_names
      assert "MyApp.Accounts.User" in component_names
      assert "MyApp.Accounts.Repo" in component_names
    end

    test "story nodes use the story title as entity_name" do
      {scope, _tmp_dir} = setup_full_project()

      {nodes, _edges} = RequirementGraph.compute_graph(scope)

      story_names =
        nodes
        |> Enum.filter(&(&1.entity_type == "story"))
        |> Enum.map(& &1.entity_name)
        |> Enum.uniq()

      assert "User Registration" in story_names
    end

    test "story requirements include bdd_specs_exist and qa_complete" do
      {scope, _tmp_dir} = setup_full_project()

      {nodes, _edges} = RequirementGraph.compute_graph(scope)

      story_req_names =
        nodes
        |> Enum.filter(&(&1.entity_type == "story"))
        |> Enum.map(& &1.name)
        |> Enum.uniq()

      assert "component_linked" in story_req_names
      assert "bdd_specs_exist" in story_req_names
      assert "qa_complete" in story_req_names
    end

    test "each node has all required Requirement struct fields" do
      {scope, _tmp_dir} = setup_full_project()

      {nodes, _edges} = RequirementGraph.compute_graph(scope)
      node = hd(nodes)

      assert is_binary(node.entity_type)
      assert node.entity_id != nil
      assert is_binary(node.name)
      assert is_boolean(node.satisfied)
      assert is_list(node.prerequisites)
      assert is_map(node.details)
      assert node.execution_type in [:main_agent, :sub_agent]
      assert node.validation_type in [:automatic, :manual]
    end

    test "next_actionable_project returns only unsatisfied nodes with met prerequisites" do
      {scope, _tmp_dir} = setup_full_project()

      actionable = Requirements.next_actionable_project(scope)

      Enum.each(actionable, fn node ->
        assert %Requirement{} = node
        refute node.satisfied
        assert node.satisfied_by != nil
      end)
    end

    test "bdd_specs_passing is NOT actionable when component tree is unsatisfied" do
      {scope, _tmp_dir} = setup_full_project()

      actionable = Requirements.next_actionable_project(scope)
      actionable_keys = MapSet.new(actionable, fn n -> {n.entity_type, n.name} end)

      # Component tree has no files yet, so bdd_specs_passing should be blocked
      refute MapSet.member?(actionable_keys, {"story", "bdd_specs_passing"})
    end

    test "personas_complete surfaces when project_setup is satisfied and no personas exist" do
      {scope, _tmp_dir} = setup_project_with_setup_only()

      actionable = Requirements.next_actionable_project(scope)
      names = MapSet.new(actionable, & &1.name)

      assert MapSet.member?(names, "personas_complete"),
             "personas_complete should surface as actionable on a project with setup but no personas — got #{inspect(MapSet.to_list(names))}"

      # stories_exist is gated behind personas_complete, so it must NOT be actionable yet.
      refute MapSet.member?(names, "stories_exist"),
             "stories_exist should be blocked until personas_complete is satisfied"

      # And architecture is still gated further down the chain.
      refute MapSet.member?(names, "architecture_designed"),
             "architecture_designed should remain blocked until stories_exist is satisfied"
    end

    test "stories_exist drops out of actionable once a story is created" do
      {scope, _tmp_dir} = setup_full_project()

      actionable = Requirements.next_actionable_project(scope)
      names = MapSet.new(actionable, & &1.name)

      refute MapSet.member?(names, "stories_exist"),
             "stories_exist should be satisfied when at least one story exists on the project"
    end
  end

  # -- Setup helpers --

  defp setup_project_with_setup_only do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

    scope = %{
      scope
      | active_project: project,
        cwd: tmp_dir,
        environment: Environment.new(:local, tmp_dir)
    }

    WorkflowHelpers.seed_all_setup_steps(tmp_dir)
    {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)
    ComponentSync.sync_from_files(scope, base_dir: tmp_dir)

    {scope, tmp_dir}
  end

  defp setup_full_project do
    {scope, tmp_dir} = setup_project_with_setup_only()

    # Create context with child component
    {:ok, context} =
      Components.create_component(scope, %{
        name: "Accounts",
        type: "context",
        module_name: "MyApp.Accounts"
      })

    {:ok, _child} =
      Components.create_component(scope, %{
        name: "User",
        type: "schema",
        module_name: "MyApp.Accounts.User",
        parent_component_id: context.id
      })

    {:ok, repo} =
      Components.create_component(scope, %{
        name: "Repo",
        type: "schema",
        module_name: "MyApp.Accounts.Repo"
      })

    # context depends on repo
    Components.create_dependency(scope, %{
      source_component_id: context.id,
      target_component_id: repo.id
    })

    {:ok, story} =
      Stories.create_story(scope, %{
        ready_for_dev: true,
        title: "User Registration",
        description: "As a user, I can register",
        acceptance_criteria: ["Can create account"]
      })

    Stories.update_story(scope, story, %{component_id: context.id})

    {scope, tmp_dir}
  end
end
