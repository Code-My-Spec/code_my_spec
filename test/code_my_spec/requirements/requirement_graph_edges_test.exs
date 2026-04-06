defmodule CodeMySpec.Requirements.RequirementGraphEdgesTest do
  @moduledoc """
  Tests for requirement graph edge computation, satisfaction clamping,
  and actionability filtering.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Projects
  alias CodeMySpec.Stories

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "satisfaction clamping" do
    test "node is clamped to unsatisfied when incoming edge source is unsatisfied" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      context = create_component(scope, "MyApp.Accounts", "context")

      {:ok, story} = Stories.create_story(scope, %{
        title: "Test Story",
        description: "As a user...",
        acceptance_criteria: ["AC1"],
        component_id: context.id
      })

      sync!(scope, tmp_dir)

      {nodes, _edges} = RequirementGraph.compute_graph(scope)

      # bdd_specs_passing should be unsatisfied — context.tests_passing is unsatisfied
      bdd_passing = find_node(nodes, "story", story.id, "bdd_specs_passing")
      assert bdd_passing
      refute bdd_passing.satisfied
    end

    test "clamping cascades: qa_complete unsatisfied when bdd_specs_passing is clamped" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      context = create_component(scope, "MyApp.Accounts", "context")

      {:ok, story} = Stories.create_story(scope, %{
        title: "Test Story",
        description: "As a user...",
        acceptance_criteria: ["AC1"],
        component_id: context.id
      })

      sync!(scope, tmp_dir)

      {nodes, _edges} = RequirementGraph.compute_graph(scope)

      qa = find_node(nodes, "story", story.id, "qa_complete")
      assert qa
      refute qa.satisfied
    end
  end

  describe "vacuous truth prevention" do
    test "tests_passing is unsatisfied when no test file exists for repository" do
      {scope, tmp_dir} = setup_project()

      # Repository type has tests_passing in its requirements
      component = create_component(scope, "MyApp.WidgetRepo", "repository")

      write_file(tmp_dir, ".code_my_spec/spec/my_app/widget_repo.spec.md", spec_content("MyApp.WidgetRepo", "repository"))
      write_file(tmp_dir, "lib/my_app/widget_repo.ex", impl_content("MyApp.WidgetRepo"))
      sync!(scope, tmp_dir)

      {nodes, _} = RequirementGraph.compute_graph(scope)

      tests_passing = find_node(nodes, "component", component.id, "tests_passing")
      assert tests_passing, "repository should have tests_passing requirement"
      refute tests_passing.satisfied, "tests_passing should not be vacuously satisfied with no test file"
    end

    test "bdd_specs_passing is unsatisfied when no bdd spec files exist" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      component = create_component(scope, "MyApp.Widget", "repository")
      {:ok, story} = Stories.create_story(scope, %{
        title: "Test Story",
        description: "As a user...",
        acceptance_criteria: ["AC1"],
        component_id: component.id
      })

      sync!(scope, tmp_dir)

      {nodes, _} = RequirementGraph.compute_graph(scope)
      bdd = find_node(nodes, "story", story.id, "bdd_specs_passing")
      assert bdd
      refute bdd.satisfied
    end
  end

  describe "story → component edges" do
    @tag :pending
    test "creates entry and exit edges for surface component" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      # Use schema — same pattern as existing working tests
      {:ok, component} = Components.create_component(scope, %{
        name: "Widget",
        type: "schema",
        module_name: "MyApp.Widget"
      })

      {:ok, story} = Stories.create_story(scope, %{
        title: "Test Story",
        description: "As a user...",
        acceptance_criteria: ["AC1"],
        component_id: component.id
      })

      # Write a file so sync detects the component
      write_file(tmp_dir, "lib/my_app/widget.ex", impl_content("MyApp.Widget"))
      sync!(scope, tmp_dir)

      {_nodes, edges} = RequirementGraph.compute_graph(scope)

      # Entry: bdd_specs_exist → component.spec_file
      entry = Enum.find(edges, fn e ->
        e.from == {"story", story.id, "bdd_specs_exist"} and
        e.to == {"component", component.id, "spec_file"}
      end)
      assert entry, "should have entry edge from story.bdd_specs_exist to component.spec_file"

      # Exit: component.implementation_file → story.bdd_specs_passing (terminal for schema)
      exit_edge = Enum.find(edges, fn e ->
        e.from == {"component", component.id, "implementation_file"} and
        e.to == {"story", story.id, "bdd_specs_passing"}
      end)
      assert exit_edge, "should have exit edge from component terminal to story.bdd_specs_passing"
    end

    @tag :pending
    test "creates edges for direct dependencies" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      # Surface component depends on a context
      {:ok, surface} = Components.create_component(scope, %{
        name: "TodoListLive", type: "live_context", module_name: "MyApp.TodoListLive"
      })
      {:ok, context} = Components.create_component(scope, %{
        name: "Todos", type: "context", module_name: "MyApp.Todos"
      })

      {:ok, _dep} = Components.create_dependency(scope, %{
        source_component_id: surface.id,
        target_component_id: context.id
      })

      {:ok, story} = Stories.create_story(scope, %{
        title: "Test Story",
        description: "As a user...",
        acceptance_criteria: ["AC1"],
        component_id: surface.id
      })

      write_file(tmp_dir, "lib/my_app/todo_list_live.ex", impl_content("MyApp.TodoListLive"))
      write_file(tmp_dir, "lib/my_app/todos.ex", impl_content("MyApp.Todos"))
      sync!(scope, tmp_dir)

      {_nodes, edges} = RequirementGraph.compute_graph(scope)

      # Should have entry edge to context (direct dependency)
      ctx_entry = Enum.find(edges, fn e ->
        e.from == {"story", story.id, "bdd_specs_exist"} and
        e.to == {"component", context.id, "spec_file"}
      end)
      assert ctx_entry, "should have entry edge to direct dependency context"
    end

    test "does not create edges to transitive dependencies" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      {:ok, surface} = Components.create_component(scope, %{
        name: "TodoListLive", type: "live_context", module_name: "MyApp.TodoListLive"
      })
      {:ok, context} = Components.create_component(scope, %{
        name: "Todos", type: "context", module_name: "MyApp.Todos"
      })
      {:ok, deep_dep} = Components.create_component(scope, %{
        name: "Accounts", type: "context", module_name: "MyApp.Accounts"
      })

      {:ok, _} = Components.create_dependency(scope, %{
        source_component_id: surface.id,
        target_component_id: context.id
      })
      {:ok, _} = Components.create_dependency(scope, %{
        source_component_id: context.id,
        target_component_id: deep_dep.id
      })

      {:ok, story} = Stories.create_story(scope, %{
        title: "Test Story",
        description: "As a user...",
        acceptance_criteria: ["AC1"],
        component_id: surface.id
      })

      write_file(tmp_dir, "lib/my_app/todo_list_live.ex", impl_content("MyApp.TodoListLive"))
      write_file(tmp_dir, "lib/my_app/todos.ex", impl_content("MyApp.Todos"))
      write_file(tmp_dir, "lib/my_app/accounts.ex", impl_content("MyApp.Accounts"))
      sync!(scope, tmp_dir)

      {_nodes, edges} = RequirementGraph.compute_graph(scope)

      # Should NOT have edges to deep_dep (transitive, not direct)
      deep_edges = Enum.filter(edges, fn e ->
        (elem(e.from, 1) == deep_dep.id and elem(e.to, 0) == "story") or
        (elem(e.to, 1) == deep_dep.id and elem(e.from, 0) == "story")
      end)
      assert deep_edges == [], "should not create edges to transitive dependencies"
    end
  end

  describe "container edges" do
    test "live_context creates container edges to liveview children" do
      {scope, tmp_dir} = setup_project()

      parent = create_component(scope, "MyApp.TodoListLive", "live_context")
      child = create_child_component(scope, "MyApp.TodoListLive.Index", "liveview", parent.id)

      sync!(scope, tmp_dir)

      {_nodes, edges} = RequirementGraph.compute_graph(scope)

      # Fan-out: parent.context_specs → child.spec_file
      fan_out = Enum.find(edges, fn e ->
        e.from == {"component", parent.id, "context_specs"} and
        e.to == {"component", child.id, "spec_file"}
      end)
      assert fan_out, "live_context should create fan-out edge to liveview child spec_file"

      # Fan-in: child.spec_valid → parent.review_file
      fan_in = Enum.find(edges, fn e ->
        e.from == {"component", child.id, "spec_valid"} and
        e.to == {"component", parent.id, "review_file"}
      end)
      assert fan_in, "liveview child should create fan-in edge to live_context review_file"
    end

    test "context creates container edges to schema children" do
      {scope, tmp_dir} = setup_project()

      parent = create_component(scope, "MyApp.Accounts", "context")
      child = create_child_component(scope, "MyApp.Accounts.User", "schema", parent.id)

      sync!(scope, tmp_dir)

      {_nodes, edges} = RequirementGraph.compute_graph(scope)

      # Fan-out: parent.context_specs → child.spec_file
      fan_out = Enum.find(edges, fn e ->
        e.from == {"component", parent.id, "context_specs"} and
        e.to == {"component", child.id, "spec_file"}
      end)
      assert fan_out, "context should create fan-out edge to schema child spec_file"

      # Fan-in: child.terminal (implementation_file for schema) → parent.implementation_file
      fan_in = Enum.find(edges, fn e ->
        e.from == {"component", child.id, "implementation_file"} and
        e.to == {"component", parent.id, "implementation_file"}
      end)
      assert fan_in, "schema child terminal should fan-in to context implementation_file"
    end
  end

  describe "driven child actionability" do
    test "child is suppressed when parent container is still active" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      parent = create_component(scope, "MyApp.Accounts", "context")
      child = create_child_component(scope, "MyApp.Accounts.User", "schema", parent.id)

      # Parent spec exists but context_specs is unsatisfied (child spec doesn't exist)
      write_file(tmp_dir, ".code_my_spec/spec/my_app/accounts.spec.md", spec_content("MyApp.Accounts", "context"))
      sync!(scope, tmp_dir)

      actionable = RequirementGraph.next_actionable(scope)
      child_actionable = Enum.filter(actionable, fn n ->
        n.entity_type == "component" and n.entity_id == child.id
      end)

      assert child_actionable == [],
        "child should be suppressed when parent context_specs is unsatisfied"
    end
  end

  describe "bdd_specs_passing prerequisites" do
    test "bdd_specs_passing has bdd_specs_exist as prerequisite edge" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      {:ok, story} = Stories.create_story(scope, %{
        title: "Test Story",
        description: "As a user...",
        acceptance_criteria: ["AC1"]
      })

      sync!(scope, tmp_dir)

      {_nodes, edges} = RequirementGraph.compute_graph(scope)

      prereq_edge = Enum.find(edges, fn e ->
        e.from == {"story", story.id, "bdd_specs_exist"} and
        e.to == {"story", story.id, "bdd_specs_passing"}
      end)

      assert prereq_edge, "bdd_specs_passing should have prerequisite edge from bdd_specs_exist"
    end

    test "bdd_specs_passing is not actionable when bdd_specs_exist is unsatisfied" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      {:ok, story} = Stories.create_story(scope, %{
        title: "Test Story",
        description: "As a user...",
        acceptance_criteria: ["AC1"]
      })

      sync!(scope, tmp_dir)

      actionable = RequirementGraph.next_actionable(scope)
      bdd_passing = Enum.find(actionable, fn n ->
        n.entity_type == "story" and n.entity_id == story.id and n.name == "bdd_specs_passing"
      end)

      refute bdd_passing, "bdd_specs_passing should not be actionable when bdd_specs_exist is unsatisfied"
    end
  end

  describe "field_present details" do
    test "component_linked details include the component_id value" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      component = create_component(scope, "MyApp.Widget", "schema")
      {:ok, story} = Stories.create_story(scope, %{
        title: "Test Story",
        description: "As a user...",
        acceptance_criteria: ["AC1"],
        component_id: component.id
      })

      sync!(scope, tmp_dir)

      # Use compute_all which doesn't do clamping based on project prereqs
      # (component_linked satisfaction is independent of project-level gates)
      nodes = RequirementGraph.compute_all(scope)
      linked = find_node(nodes, "story", story.id, "component_linked")

      assert linked
      # component_linked uses field_present check — the field value should be in details
      assert linked.details[:component_id] == component.id ||
             linked.details["component_id"] == component.id,
        "field_present details should include the field name as key, got: #{inspect(linked.details)}"
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

  defp create_component(scope, module_name, type) do
    name = module_name |> String.split(".") |> List.last()

    {:ok, component} =
      Components.create_component(scope, %{
        name: name,
        type: type,
        module_name: module_name
      })

    component
  end

  defp create_child_component(scope, module_name, type, parent_id) do
    component = create_component(scope, module_name, type)
    {:ok, component} = Components.update_component(scope, component, %{parent_component_id: parent_id})
    component
  end

  defp find_node(nodes, entity_type, entity_id, name) do
    Enum.find(nodes, fn n ->
      n.entity_type == entity_type and n.entity_id == entity_id and n.name == name
    end)
  end

  defp sync!(scope, tmp_dir) do
    {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)
    CodeMySpec.Files.ComponentSync.sync_from_files(scope, base_dir: tmp_dir)
  end

  defp seed_setup(tmp_dir) do
    CodeMySpec.Integration.WorkflowHelpers.seed_all_setup_steps(tmp_dir)
  end

  defp write_file(tmp_dir, relative_path, content) do
    full_path = Path.join(tmp_dir, relative_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
  end

  defp spec_content(module_name, type) do
    """
    # #{module_name}

    A test component.

    ## Type

    #{type}
    """
  end

  defp impl_content(module_name) do
    """
    defmodule #{module_name} do
      @moduledoc false
    end
    """
  end
end
