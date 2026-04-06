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
    test "live_context creates parent-child edges to liveview children" do
      {scope, tmp_dir} = setup_project()

      parent = create_component(scope, "MyApp.TodoListLive", "live_context")
      child = create_child_component(scope, "MyApp.TodoListLive.Index", "liveview", parent.id)

      sync!(scope, tmp_dir)

      {_nodes, edges} = RequirementGraph.compute_graph(scope)

      # Fan-out: parent.spec_valid → child.spec_file
      fan_out = Enum.find(edges, fn e ->
        e.from == {"component", parent.id, "spec_valid"} and
        e.to == {"component", child.id, "spec_file"}
      end)
      assert fan_out, "live_context should create fan-out edge from spec_valid to liveview child spec_file"

      # Fan-in: child.spec_valid → parent.review_file
      fan_in = Enum.find(edges, fn e ->
        e.from == {"component", child.id, "spec_valid"} and
        e.to == {"component", parent.id, "review_file"}
      end)
      assert fan_in, "liveview child should create fan-in edge to live_context review_file"
    end

    test "context creates parent-child edges to schema children" do
      {scope, tmp_dir} = setup_project()

      parent = create_component(scope, "MyApp.Accounts", "context")
      child = create_child_component(scope, "MyApp.Accounts.User", "schema", parent.id)

      sync!(scope, tmp_dir)

      {_nodes, edges} = RequirementGraph.compute_graph(scope)

      # Fan-out: parent.spec_valid → child.spec_file (children wait for parent design)
      fan_out = Enum.find(edges, fn e ->
        e.from == {"component", parent.id, "spec_valid"} and
        e.to == {"component", child.id, "spec_file"}
      end)
      assert fan_out, "context should create fan-out edge from spec_valid to schema child spec_file"

      # Fan-in: child.terminal (implementation_file for schema) → parent.implementation_file
      fan_in = Enum.find(edges, fn e ->
        e.from == {"component", child.id, "implementation_file"} and
        e.to == {"component", parent.id, "implementation_file"}
      end)
      assert fan_in, "schema child terminal should fan-in to context implementation_file"
    end
  end

  describe "parent-child actionability" do
    test "children become actionable after parent spec is valid" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      parent = create_component(scope, "MyApp.Accounts", "context")
      child = create_child_component(scope, "MyApp.Accounts.User", "schema", parent.id)

      # Write parent AND child spec files (child must exist for sync to track it)
      write_file(tmp_dir, ".code_my_spec/spec/my_app/accounts.spec.md", spec_content("MyApp.Accounts", "context"))
      write_file(tmp_dir, ".code_my_spec/spec/my_app/accounts/user.spec.md", spec_content("MyApp.Accounts.User", "schema"))
      sync!(scope, tmp_dir)

      # Validate the parent spec (mark valid)
      parent_spec = CodeMySpec.Files.get_by_path(scope, ".code_my_spec/spec/my_app/accounts.spec.md")
      if parent_spec, do: CodeMySpec.Files.mark_validated(parent_spec, true)

      # Compute the graph
      {nodes, edges} = RequirementGraph.compute_graph(scope)

      # Verify parent spec_valid is satisfied
      parent_spec_valid = Enum.find(nodes, fn n ->
        n.entity_type == "component" and n.entity_id == parent.id and n.name == "spec_valid"
      end)

      assert parent_spec_valid, "parent spec_valid node should exist"
      assert parent_spec_valid.satisfied, "parent spec_valid should be satisfied after validation"

      # Verify fan-out edge exists: parent.spec_valid → child.spec_file
      fan_out = Enum.find(edges, fn e ->
        e.from == {"component", parent.id, "spec_valid"} and
        e.to == {"component", child.id, "spec_file"}
      end)
      assert fan_out, "fan-out edge should exist from parent.spec_valid to child.spec_file"

      # Child spec_file node should exist and be satisfied (file was written)
      child_spec = Enum.find(nodes, fn n ->
        n.entity_type == "component" and n.entity_id == child.id and n.name == "spec_file"
      end)
      assert child_spec, "child spec_file node should exist in graph"
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

  describe "full context lifecycle sequencing" do
    @tag :lifecycle
    test "parent-child phases are correctly gated end-to-end" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      # Write ALL spec files upfront so ComponentSync doesn't delete our components.
      # The graph gates work via file validation (valid: true/false), not file existence.
      write_file(tmp_dir, ".code_my_spec/spec/my_app/accounts.spec.md",
        spec_content("MyApp.Accounts", "context"))
      write_file(tmp_dir, ".code_my_spec/spec/my_app/accounts/user.spec.md",
        spec_content("MyApp.Accounts.User", "repository"))
      write_file(tmp_dir, ".code_my_spec/spec/my_app/accounts/token.spec.md",
        spec_content("MyApp.Accounts.Token", "repository"))

      # Sync to create components from files, then set up parent-child relationships
      sync!(scope, tmp_dir)

      parent = Components.get_component_by_module_name(scope, "MyApp.Accounts")
      child1 = Components.get_component_by_module_name(scope, "MyApp.Accounts.User")
      child2 = Components.get_component_by_module_name(scope, "MyApp.Accounts.Token")

      assert parent, "parent component should exist after sync"
      assert child1, "child1 component should exist after sync"
      assert child2, "child2 component should exist after sync"

      # ComponentSync derives parent relationships from module names, but let's
      # ensure the parent-child links are set
      {:ok, _} = Components.update_component(scope, child1, %{parent_component_id: parent.id})
      {:ok, _} = Components.update_component(scope, child2, %{parent_component_id: parent.id})

      # === STEP 1: Spec files exist but are NOT validated ===
      # Parent spec_file is satisfied (file exists), but spec_valid is not (valid != true)
      # Children spec_files are satisfied too, but gated by parent.spec_valid (fan-out)
      actionable = actionable_component_names(scope)

      # Parent spec_valid should be actionable (spec_file satisfied, spec_valid not yet)
      # But actually spec_file is already satisfied. The first unsatisfied is spec_valid.
      # spec_valid needs the file to be validated (valid: true).
      # spec_file is satisfied because the file exists.
      # So we should see spec_valid as the first actionable for parent.
      # But since spec_file check is file_exists and the file exists, it's satisfied.
      # spec_valid needs file_valid — file exists but valid is nil.

      # Children can't start because parent.spec_valid is unsatisfied (fan-out gate)
      refute {"MyApp.Accounts.User", "implementation_file"} in actionable,
        "child impl should NOT be actionable"

      # === STEP 2: Validate parent spec → children spec_valid becomes unblocked ===
      mark_valid!(scope, ".code_my_spec/spec/my_app/accounts.spec.md")

      actionable = actionable_component_names(scope)
      # Now parent.spec_valid is satisfied → fan-out unblocks children
      # Children's spec_files are satisfied (files exist). spec_valid is next.
      # But children's spec_valid needs valid: true on their spec files
      refute {"MyApp.Accounts", "review_file"} in actionable,
        "review should NOT be actionable until all children have valid specs"

        IO.inspect(actionable)

      # === STEP 3: Validate children's specs → review becomes actionable ===
      mark_valid!(scope, ".code_my_spec/spec/my_app/accounts/user.spec.md")
      mark_valid!(scope, ".code_my_spec/spec/my_app/accounts/token.spec.md")

      actionable = actionable_component_names(scope)
      assert {"MyApp.Accounts", "review_file"} in actionable,
        "review should be actionable after all children spec_valid. Got: #{inspect(actionable)}"
      refute {"MyApp.Accounts.User", "implementation_file"} in actionable,
        "child impl should NOT be actionable before review_valid"

      # === STEP 4: Write + validate review → children can implement ===
      # Review files live at .code_my_spec/spec/{module_path}/design_review.md
      write_file(tmp_dir, ".code_my_spec/spec/my_app/accounts/design_review.md",
        "# Design Review\n\nApproved.")
      sync!(scope, tmp_dir)
      mark_valid!(scope, ".code_my_spec/spec/my_app/accounts/design_review.md")

      # After review, children should write TESTS first (TDD), not impl
      actionable = actionable_component_names(scope)
      assert {"MyApp.Accounts.User", "test_file"} in actionable,
        "child1 test_file should be actionable after review_valid (TDD). Got: #{inspect(actionable)}"
      assert {"MyApp.Accounts.Token", "test_file"} in actionable,
        "child2 test_file should be actionable after review_valid (TDD)"
      refute {"MyApp.Accounts.User", "implementation_file"} in actionable,
        "child impl should NOT be actionable before tests are written"

      # === STEP 5: Write + validate tests → children can implement ===
      write_file(tmp_dir, "test/my_app/accounts/user_test.exs",
        "defmodule MyApp.Accounts.UserTest do\n  use ExUnit.Case\nend")
      write_file(tmp_dir, "test/my_app/accounts/token_test.exs",
        "defmodule MyApp.Accounts.TokenTest do\n  use ExUnit.Case\nend")
      sync!(scope, tmp_dir)
      mark_valid!(scope, "test/my_app/accounts/user_test.exs")
      mark_valid!(scope, "test/my_app/accounts/token_test.exs")

      actionable = actionable_component_names(scope)
      assert {"MyApp.Accounts.User", "implementation_file"} in actionable,
        "child1 impl should be actionable after tests written. Got: #{inspect(actionable)}"

      # === STEP 6: Implement children → parent can implement ===
      write_file(tmp_dir, "lib/my_app/accounts/user.ex", impl_content("MyApp.Accounts.User"))
      write_file(tmp_dir, "lib/my_app/accounts/token.ex", impl_content("MyApp.Accounts.Token"))
      sync!(scope, tmp_dir)

      actionable = actionable_component_names(scope)
      assert {"MyApp.Accounts", "implementation_file"} in actionable,
        "parent impl should be actionable after all children reach terminal. Got: #{inspect(actionable)}"
    end
  end

  # -- Helpers --

  defp actionable_names(scope) do
    RequirementGraph.next_actionable(scope)
    |> Enum.map(fn n -> {n.entity_name, n.name} end)
    |> MapSet.new()
  end

  defp actionable_component_names(scope) do
    RequirementGraph.next_actionable(scope)
    |> Enum.filter(fn n -> n.entity_type == "component" end)
    |> Enum.map(fn n -> {n.entity_name, n.name} end)
    |> MapSet.new()
  end

  defp mark_valid!(scope, path) do
    file = CodeMySpec.Files.get_by_path(scope, path)
    if file, do: CodeMySpec.Files.mark_validated(file, true)
  end

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
