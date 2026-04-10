defmodule CodeMySpec.Requirements.RequirementGraphTest do
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Projects
  alias CodeMySpec.Stories

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "next_actionable/1" do
    test "returns project_setup when no setup is done" do
      {scope, tmp_dir} = setup_project()

      # Write mix.exs so it looks like a project dir (but setup incomplete)
      write_file(tmp_dir, "mix.exs", "defmodule MyApp.MixProject do\n  use Mix.Project\nend")

      actionable = RequirementGraph.next_actionable(scope)

      # project_setup should be first actionable (no prerequisites)
      first = List.first(actionable)
      assert first
      assert first.entity_type == "project"
      assert first.name == "project_setup"
    end

    test "returns component spec requirements when project setup is complete" do
      {scope, tmp_dir} = setup_project()

      # Seed project setup files
      seed_setup(tmp_dir)
      sync!(scope, tmp_dir)

      # Create a component without a spec
      {:ok, component} =
        Components.create_component(scope, %{
          name: "Widget",
          type: "schema",
          module_name: "MyApp.Widget"
        })

      write_file(tmp_dir, "lib/my_app/widget.ex", "defmodule MyApp.Widget do\nend")
      sync!(scope, tmp_dir)

      actionable = RequirementGraph.next_actionable(scope)
      names = Enum.map(actionable, & &1.name)

      # Component needs a spec (spec_file is first requirement for schema)
      assert "spec_file" in names
    end

    test "story component_linked is blocked when project prerequisites are unsatisfied" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      {:ok, _story} =
        Stories.create_story(scope, %{
          title: "Test Story",
          description: "As a user...",
          acceptance_criteria: ["AC1"]
        })

      sync!(scope, tmp_dir)

      actionable = RequirementGraph.next_actionable(scope)
      story_reqs = Enum.filter(actionable, &(&1.entity_type == "story"))

      # component_linked is blocked by issues_resolved which depends on the
      # full project prerequisite chain (technical_strategy, architecture_designed, etc.)
      refute Enum.any?(story_reqs, &(&1.name == "component_linked"))
    end
  end

  describe "compute_all/1" do
    test "returns nodes for all three entity levels" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      {:ok, _} =
        Components.create_component(scope, %{
          name: "Widget",
          type: "schema",
          module_name: "MyApp.Widget"
        })

      {:ok, _} =
        Stories.create_story(scope, %{
          title: "Test Story",
          description: "As a user...",
          acceptance_criteria: ["AC1"]
        })

      sync!(scope, tmp_dir)

      nodes = RequirementGraph.compute_all(scope)
      types = nodes |> Enum.map(& &1.entity_type) |> Enum.uniq() |> Enum.sort()

      assert types == ["component", "project", "story"]
    end

    test "component satisfaction reflects file state" do
      {scope, tmp_dir} = setup_project()

      {:ok, component} =
        Components.create_component(scope, %{
          name: "Widget",
          type: "schema",
          module_name: "MyApp.Widget"
        })

      # No files → spec_file unsatisfied
      nodes = RequirementGraph.compute_all(scope)

      widget_spec =
        Enum.find(nodes, fn n ->
          n.entity_type == "component" and n.entity_id == component.id and n.name == "spec_file"
        end)

      assert widget_spec
      refute widget_spec.satisfied

      # Add spec file → spec_file satisfied
      write_file(tmp_dir, ".code_my_spec/spec/my_app/widget.spec.md", "# MyApp.Widget\n\n## Type\n\nschema")
      sync!(scope, tmp_dir)

      nodes2 = RequirementGraph.compute_all(scope)

      widget_spec2 =
        Enum.find(nodes2, fn n ->
          n.entity_type == "component" and n.entity_id == component.id and n.name == "spec_file"
        end)

      assert widget_spec2.satisfied
    end
  end

  describe "parent resolution" do
    test "context parent-scope nodes are parented by the context itself" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      # Create spec files so ComponentSync creates and retains the components
      write_file(tmp_dir, ".code_my_spec/spec/my_app/todos.spec.md", "# MyApp.Todos\n\n## Type\n\ncontext\n\n## Components\n\n- MyApp.Todos.Todo")
      write_file(tmp_dir, ".code_my_spec/spec/my_app/todos/todo.spec.md", "# MyApp.Todos.Todo\n\n## Type\n\nschema\n\n## Fields\n\n- title: string")

      sync!(scope, tmp_dir)

      # Find the components created by sync
      all_components = Components.list_components(scope)
      context = Enum.find(all_components, &(&1.module_name == "MyApp.Todos"))
      schema = Enum.find(all_components, &(&1.module_name == "MyApp.Todos.Todo"))

      assert context, "Context component should exist"
      assert schema, "Schema component should exist"

      nodes = RequirementGraph.compute_all(scope)

      # Child schema nodes should be parented by the context
      child_nodes =
        Enum.filter(nodes, fn n ->
          n.entity_type == "component" and n.entity_id == schema.id
        end)

      assert child_nodes != [], "Expected child nodes for schema #{schema.id}"

      for node <- child_nodes do
        assert node.parent_entity_id == context.id,
               "Child node #{node.name} should be parented by context, got #{inspect(node.parent_entity_id)}"

        assert node.parent_entity_name == "MyApp.Todos",
               "Child node #{node.name} should have context name as parent_entity_name"
      end

      # Context parent-scope nodes (review_file, etc.) should also be parented by the context
      context_nodes =
        Enum.filter(nodes, fn n ->
          n.entity_type == "component" and n.entity_id == context.id and n.orchestrated_by != nil
        end)

      assert context_nodes != []

      for node <- context_nodes do
        assert node.parent_entity_id == context.id,
               "Context node #{node.name} should self-parent, got #{inspect(node.parent_entity_id)}"

        assert node.parent_entity_name == "MyApp.Todos",
               "Context node #{node.name} should have context name as parent_entity_name"
      end
    end

    test "story nodes are parented by the project" do
      {scope, tmp_dir} = setup_project()

      {:ok, _story} =
        Stories.create_story(scope, %{
          title: "User Login",
          description: "As a user...",
          acceptance_criteria: ["AC1"]
        })

      seed_setup(tmp_dir)
      sync!(scope, tmp_dir)

      nodes = RequirementGraph.compute_all(scope)

      story_nodes = Enum.filter(nodes, &(&1.entity_type == "story"))
      assert story_nodes != []

      for node <- story_nodes do
        assert node.parent_entity_id == scope.active_project.id,
               "Story node #{node.name} should be parented by project"

        assert node.parent_entity_name == scope.active_project.name,
               "Story node #{node.name} should have project name as parent_entity_name"
      end
    end

    test "project nodes have no parent" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)
      sync!(scope, tmp_dir)

      nodes = RequirementGraph.compute_all(scope)
      project_nodes = Enum.filter(nodes, &(&1.entity_type == "project"))

      assert project_nodes != []

      for node <- project_nodes do
        assert node.parent_entity_id == nil,
               "Project node #{node.name} should have no parent"

        assert node.parent_entity_name == nil,
               "Project node #{node.name} should have no parent name"
      end
    end

    test "no orchestrated node has nil parent_entity_name" do
      {scope, tmp_dir} = setup_project()

      {:ok, _story} =
        Stories.create_story(scope, %{
          title: "Registration",
          description: "As a user...",
          acceptance_criteria: ["AC1"]
        })

      seed_setup(tmp_dir)

      write_file(tmp_dir, ".code_my_spec/spec/my_app/accounts.spec.md", "# MyApp.Accounts\n\n## Type\n\ncontext\n\n## Components\n\n- MyApp.Accounts.User")
      write_file(tmp_dir, ".code_my_spec/spec/my_app/accounts/user.spec.md", "# MyApp.Accounts.User\n\n## Type\n\nschema\n\n## Fields\n\n- email: string")

      sync!(scope, tmp_dir)

      nodes = RequirementGraph.compute_all(scope)

      orchestrated = Enum.filter(nodes, & &1.orchestrated_by)

      assert orchestrated != []

      unknown_nodes = Enum.filter(orchestrated, &is_nil(&1.parent_entity_name))

      assert unknown_nodes == [],
             "Found orchestrated nodes with nil parent_entity_name: #{inspect(Enum.map(unknown_nodes, &{&1.entity_type, &1.entity_id, &1.name}))}"
    end
  end

  # -- Helpers --

  defp setup_project do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

    scope = %{
      scope
      | active_project: project,
        cwd: tmp_dir,
        environment: Environment.new(:local, tmp_dir)
    }

    {scope, tmp_dir}
  end

  defp sync!(scope, tmp_dir) do
    {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)
    CodeMySpec.Files.ComponentSync.sync_from_files(scope, base_dir: tmp_dir)
  end

  defp seed_setup(tmp_dir) do
    # Minimal files to make project_setup pass
    CodeMySpec.Integration.WorkflowHelpers.seed_all_setup_steps(tmp_dir)
  end

  defp write_file(tmp_dir, relative_path, content) do
    full_path = Path.join(tmp_dir, relative_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
  end
end
