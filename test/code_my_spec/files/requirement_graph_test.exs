defmodule CodeMySpec.Files.RequirementGraphTest do
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Files.RequirementGraph
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

    test "story component_linked is actionable when story has no component" do
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

      assert Enum.any?(story_reqs, &(&1.name == "component_linked"))
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
