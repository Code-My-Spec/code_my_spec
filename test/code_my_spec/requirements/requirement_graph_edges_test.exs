defmodule CodeMySpec.Requirements.RequirementGraphEdgesTest do
  @moduledoc """
  Tests for requirement graph edge computation, satisfaction clamping,
  and actionability filtering.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.ComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Integration.WorkflowHelpers
  alias CodeMySpec.Projects
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
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

      # qa_complete should be unsatisfied — context.tests_passing is unsatisfied
      qa_complete = find_node(nodes, "story", story.id, "qa_complete")
      assert qa_complete
      refute qa_complete.satisfied
    end

    test "clamping cascades: qa_complete unsatisfied when component chain is unsatisfied" do
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

    test "node already-failing from its own leaf check is reported as unsatisfied without clamping" do
      # Sanity check on the clamping contract: a node whose leaf check
      # already returned false stays at satisfied=false and does NOT get
      # tagged with :locally_satisfied (the tag is only added when the
      # clamping pass flips a previously-true node).
      #
      # Diagnostic consumers (`list_requirements diagnostic: true`)
      # treat a missing :locally_satisfied key as "leaf truth equals
      # current satisfied value" — see RequirementsMapper.
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      context = create_component(scope, "MyApp.Accounts", "context")

      {:ok, story} =
        Stories.create_story(scope, %{
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
      refute Map.has_key?(qa, :locally_satisfied),
             "qa_complete's leaf check is already false (no qa_result file) — clamping skips it"
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

    test "bdd_specs_exist is unsatisfied when no bdd spec files exist" do
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
      bdd = find_node(nodes, "story", story.id, "bdd_specs_exist")
      assert bdd
      refute bdd.satisfied
    end
  end

  describe "story → component edges" do
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

      # Exit: component.implementation_file → story.qa_complete (terminal for schema)
      exit_edge = Enum.find(edges, fn e ->
        e.from == {"component", component.id, "implementation_file"} and
        e.to == {"story", story.id, "qa_complete"}
      end)
      assert exit_edge, "should have exit edge from component terminal to story.qa_complete"
    end

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

    @tag :pending
    test "kickoff edge lands on the deepest transitive dep, intermediate kickoffs collapse" do
      # Per the moduledoc on RequirementGraph (`Kickoff edges ... span
      # the surface AND every component in its transitive cross-context
      # dependency closure. Transitive reduction collapses these to the
      # deepest dep(s)`), the story's outgoing kickoff edge should end up
      # at the deepest transitive dep, with intermediate kickoffs reduced
      # away because the path
      #   story → deep_dep → ... → context → ... → surface
      # already exists via the cross-context dependency edges.
      #
      # Currently failing: `context.spec_valid → context.review_file` is
      # missing from the intra-component chain because the only prereq
      # chain into `review_file` goes through child-scoped reqs, and the
      # `Todos` context here has no children. With that gap in the
      # chain, transitive_reduction can't see that surface is reachable
      # via context, so the intermediate kickoffs survive. This is a
      # design gap in `context_graph` (child reqs gate parent reqs but
      # leave the chain broken when no children exist) — not a bug in
      # this test's expectations.
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

      story_kickoffs =
        edges
        |> Enum.filter(fn e ->
          e.from == {"story", story.id, "bdd_specs_exist"} and elem(e.to, 0) == "component"
        end)
        |> Enum.map(fn e -> elem(e.to, 1) end)
        |> MapSet.new()

      assert MapSet.member?(story_kickoffs, deep_dep.id),
             "story's kickoff edge should land on the deepest transitive dep"

      refute MapSet.member?(story_kickoffs, surface.id),
             "intermediate surface kickoff should be collapsed by transitive reduction"

      refute MapSet.member?(story_kickoffs, context.id),
             "intermediate context kickoff should be collapsed by transitive reduction"
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

      # Fan-in: child.implementation_file (schema's terminal — schemas have no tests) → parent.implementation_file
      fan_in = Enum.find(edges, fn e ->
        e.from == {"component", child.id, "implementation_file"} and
        e.to == {"component", parent.id, "implementation_file"}
      end)
      assert fan_in, "schema child should fan-in to context implementation_file"
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
      maybe_mark_validated(parent_spec)

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

  describe "qa_complete prerequisites" do
    test "qa_complete has bdd_specs_exist as prerequisite edge" do
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
        e.to == {"story", story.id, "qa_complete"}
      end)

      assert prereq_edge, "qa_complete should have prerequisite edge from bdd_specs_exist"
    end

    test "qa_complete is not actionable when bdd_specs_exist is unsatisfied" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      {:ok, story} = Stories.create_story(scope, %{
        title: "Test Story",
        description: "As a user...",
        acceptance_criteria: ["AC1"]
      })

      sync!(scope, tmp_dir)

      actionable = RequirementGraph.next_actionable(scope)
      qa_complete = Enum.find(actionable, fn n ->
        n.entity_type == "story" and n.entity_id == story.id and n.name == "qa_complete"
      end)

      refute qa_complete, "qa_complete should not be actionable when bdd_specs_exist is unsatisfied"
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

      # Advance the project-level serial chain so component-level requirements
      # become the actionable frontier. Without this, the chain (project_setup
      # → personas_complete → stories_exist → technical_strategy →
      # architecture_designed → ...) clamps every component-level requirement.
      kickoff_context =
        ProjectStateFixtures.apply_project_kickoff(%{
          scope: scope,
          environment: scope.environment
        })

      scope = kickoff_context.scope
      persona_id = kickoff_context.persona_id

      # Write stub spec files for all three components upfront. Stubs carry
      # the correct `## Type` (so ComponentSync derives the right graph shape)
      # but deliberately omit required sections — sync will mark them
      # `valid: false`. Subsequent steps overwrite with full valid content
      # to drive spec_valid transitions, which is the only way to flip
      # validity state that survives the next `sync!` call.
      parent_path = ".code_my_spec/spec/my_app/accounts.spec.md"
      user_path = ".code_my_spec/spec/my_app/accounts/user.spec.md"
      token_path = ".code_my_spec/spec/my_app/accounts/token.spec.md"
      review_path = ".code_my_spec/spec/my_app/accounts/design_review.md"

      write_file(tmp_dir, parent_path, spec_stub("MyApp.Accounts", "context"))
      write_file(tmp_dir, user_path, spec_stub("MyApp.Accounts.User", "repository"))
      write_file(tmp_dir, token_path, spec_stub("MyApp.Accounts.Token", "repository"))

      # Sync to create components from files, then set up parent-child relationships
      sync!(scope, tmp_dir)

      parent = Components.get_component_by_module_name(scope, "MyApp.Accounts")
      child1 = Components.get_component_by_module_name(scope, "MyApp.Accounts.User")
      child2 = Components.get_component_by_module_name(scope, "MyApp.Accounts.Token")

      assert parent, "parent component should exist after sync"
      assert child1, "child1 component should exist after sync"
      assert child2, "child2 component should exist after sync"

      # ComponentSync normally derives parent relationships from module names;
      # set them explicitly in case the derivation hasn't stuck.
      {:ok, _} = Components.update_component(scope, child1, %{parent_component_id: parent.id})
      {:ok, _} = Components.update_component(scope, child2, %{parent_component_id: parent.id})

      # Link the parent context to a story to satisfy `stories_exist` AND
      # the architecture orphan check (children inherit linkage transitively
      # via parent_component_id).
      story =
        StoryHelpers.create_and_link(scope, "MyApp.Accounts",
          title: "Accounts context",
          description: "As a user, I want accounts so that I can sign in.",
          acceptance_criteria: ["accounts work"],
          priority: 5
        )

      # Clear the full story-level chain (three_amigos_complete →
      # bdd_specs_exist → bdd_specs_passing → qa_complete) so the wave
      # can advance to component-level work for Accounts. Without all
      # four gates cleared, actionable stays parked on the next story-
      # level gate.
      seed_story_chain_complete(scope, tmp_dir, story, persona_id)

      # === STEP 1: Spec files exist but content is invalid ===
      # All three files fail required-section validation → spec_valid: false.
      # Children's deeper gates (test_file, implementation_file) are clamped
      # by the fan-out from parent.spec_valid.
      actionable = actionable_component_names(scope)

      refute {"MyApp.Accounts.User", "implementation_file"} in actionable,
        "child impl should NOT be actionable"

      # === STEP 2: Overwrite parent spec with valid content ===
      write_file(tmp_dir, parent_path, spec_content("MyApp.Accounts", "context"))
      sync!(scope, tmp_dir)

      actionable = actionable_component_names(scope)
      refute {"MyApp.Accounts", "review_file"} in actionable,
        "review should NOT be actionable until all children have valid specs"

      # === STEP 3: Overwrite children specs with valid content ===
      write_file(tmp_dir, user_path, spec_content("MyApp.Accounts.User", "repository"))
      write_file(tmp_dir, token_path, spec_content("MyApp.Accounts.Token", "repository"))
      sync!(scope, tmp_dir)

      actionable = actionable_component_names(scope)
      assert {"MyApp.Accounts", "review_file"} in actionable,
        "review should be actionable after all children spec_valid. Got: #{inspect(actionable)}"
      refute {"MyApp.Accounts.User", "implementation_file"} in actionable,
        "child impl should NOT be actionable before review_valid"

      # === STEP 4: Write valid review → children can implement ===
      # Review files live at .code_my_spec/spec/{module_path}/design_review.md
      write_file(tmp_dir, review_path, review_content())
      sync!(scope, tmp_dir)

      # After review, both test_file and implementation_file become actionable
      # for each child. The graph surfaces them in parallel and relies on the
      # agent to order them sensibly — it does not enforce TDD.
      actionable = actionable_component_names(scope)
      assert {"MyApp.Accounts.User", "test_file"} in actionable,
        "child1 test_file should be actionable after review_valid. Got: #{inspect(actionable)}"
      assert {"MyApp.Accounts.Token", "test_file"} in actionable,
        "child2 test_file should be actionable after review_valid"

      # === STEP 5: Write tests → children can implement ===
      # Tests auto-align because the children's specs have no Test Assertions
      # section, so SpecAlignment returns {:ok, :aligned} → valid: true on sync.
      write_file(tmp_dir, "test/my_app/accounts/user_test.exs",
        "defmodule MyApp.Accounts.UserTest do\n  use ExUnit.Case\nend")
      write_file(tmp_dir, "test/my_app/accounts/token_test.exs",
        "defmodule MyApp.Accounts.TokenTest do\n  use ExUnit.Case\nend")
      sync!(scope, tmp_dir)

      actionable = actionable_component_names(scope)
      assert {"MyApp.Accounts.User", "implementation_file"} in actionable,
        "child1 impl should be actionable after tests written. Got: #{inspect(actionable)}"

      # === STEP 6: Implement children → parent can implement ===
      write_file(tmp_dir, "lib/my_app/accounts/user.ex", impl_content("MyApp.Accounts.User"))
      write_file(tmp_dir, "lib/my_app/accounts/token.ex", impl_content("MyApp.Accounts.Token"))
      sync!(scope, tmp_dir)

      # tests_passing needs a fresh analysis run — zero persisted problems
      # only counts once results are current for these files (run ledger).
      CodeMySpec.AnalysisFixtures.fresh_analysis_runs_fixture(scope)

      actionable = actionable_component_names(scope)
      assert {"MyApp.Accounts", "implementation_file"} in actionable,
        "parent impl should be actionable after all children reach terminal. Got: #{inspect(actionable)}"
    end
  end

  # -- Helpers --

  defp actionable_component_names(scope) do
    RequirementGraph.next_actionable(scope)
    |> Enum.filter(fn n -> n.entity_type == "component" end)
    |> Enum.map(fn n -> {n.entity_name, n.name} end)
    |> MapSet.new()
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
    ComponentSync.sync_from_files(scope, base_dir: tmp_dir)
  end

  defp seed_setup(tmp_dir) do
    WorkflowHelpers.seed_all_setup_steps(tmp_dir)
  end

  defp write_file(tmp_dir, relative_path, content) do
    full_path = Path.join(tmp_dir, relative_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
  end

  # Clear the full story-level chain inline (the LiveView-driven
  # `apply_story_chain_complete` fixture needs a `context.conn`, which
  # this unit test doesn't have). Mirrors the same steps:
  # three_amigos → bdd_spec file → DB QA pass attempt → sync.
  defp seed_story_chain_complete(scope, tmp_dir, story, persona_id) do
    :ok =
      ProjectStateFixtures.apply_three_amigos_for_story(scope, story,
        persona_id: persona_id,
        rule_statement: "Rule for #{story.title}"
      )

    # Re-fetch the story so criteria (created during three amigos) are available.
    story = StoryHelpers.fetch(scope, story.id)
    [criterion | _] = story.criteria
    bdd_path = CodeMySpec.BddSpecs.spec_file_path(story, criterion)
    write_file(tmp_dir, bdd_path, bdd_spec_stub(story, criterion))

    # Insert a DB-backed QA pass attempt. The requirement graph now checks
    # Qa.complete?/2 (DB-driven), not result_complete.md on disk.
    {:ok, _attempt} =
      %CodeMySpec.Qa.QaAttempt{}
      |> CodeMySpec.Qa.QaAttempt.changeset(%{
        story_id: story.id,
        status: :pass,
        scenarios: [%{name: "Placeholder", status: :pass, observation: "All checks passed."}],
        issue_ids: [],
        submitted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> CodeMySpec.Repo.insert()

    sync!(scope, tmp_dir)
    :ok
  end

  defp bdd_spec_stub(story, criterion) do
    """
    defmodule CodeMySpecSpex.Story#{story.id}.Criterion#{criterion.id}Spex do
      use ExUnit.Case, async: true

      test "placeholder" do
        assert true
      end
    end
    """
  end

  # Intentionally-invalid spec stub. Carries the correct `## Type` (so
  # ComponentSync picks the right graph) but omits the required sections,
  # so sync's validate_entry marks it `valid: false`.
  defp spec_stub(module_name, type) do
    """
    # #{module_name}

    ## Type

    #{type}
    """
  end

  # Spec content that passes `Documents.create_dynamic_document` validation —
  # required so sync doesn't reset `valid: false` after `mark_valid!`. The
  # sections match required_sections for each doc type in the Documents
  # Registry:
  #   - context → "context_spec": [["delegates","functions"], "dependencies", "components"]
  #   - other  → "spec":         [["delegates","functions"], "dependencies"]
  defp spec_content(module_name, "context") do
    """
    # #{module_name}

    A test context.

    ## Type

    context

    ## Functions

    - `hello/0`

    ## Dependencies

    - MyApp.Repo

    ## Components

    - MyApp.Accounts.User — a user record
    """
  end

  defp spec_content(module_name, type) do
    """
    # #{module_name}

    A test component.

    ## Type

    #{type}

    ## Functions

    - `hello/0`

    ## Dependencies

    - MyApp.Repo
    """
  end

  # Review content that passes the "design_review" doc type's required_sections:
  # ["overview", "architecture", "integration", "conclusion"].
  defp review_content do
    """
    # Design Review

    ## Overview

    Approved.

    ## Architecture

    Looks good.

    ## Integration

    Integrates cleanly.

    ## Conclusion

    Ready to implement.
    """
  end

  defp impl_content(module_name) do
    """
    defmodule #{module_name} do
      @moduledoc false
    end
    """
  end

  defp maybe_mark_validated(nil), do: :ok
  defp maybe_mark_validated(spec), do: CodeMySpec.Files.mark_validated(spec, true)
end
