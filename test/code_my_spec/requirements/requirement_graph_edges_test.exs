defmodule CodeMySpec.Requirements.RequirementGraphEdgesTest do
  @moduledoc """
  Tests for requirement graph edge computation, satisfaction clamping,
  and actionability filtering.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures
  alias CodeMySpec.ConfigurationsFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.ComponentSync
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Integration.WorkflowHelpers
  alias CodeMySpec.Projects
  alias CodeMySpec.Qa.QaAttempt
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

      {:ok, story} =
        Stories.create_story(scope, %{
          ready_for_dev: true,
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

      {:ok, story} =
        Stories.create_story(scope, %{
          ready_for_dev: true,
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
          ready_for_dev: true,
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

  # A parent whose first def is `:child`-scoped fans out to its children, and a
  # child in the same kickoff closure emits the identical edge for itself. Both
  # paths ran, so the component tree produced 13,433 duplicates on this project
  # — uniformly ×2, none higher, which is the signature of exactly two paths
  # reaching one edge.
  #
  # `Enum.uniq/1` already removed them before the reduction, so suppressing the
  # parent's copy cannot change the graph. These assert that: the edge survives,
  # and nothing is emitted twice.
  describe "the parent/child fan-out no longer emits an edge twice" do
    defp parent_and_child(scope, tmp_dir) do
      {:ok, parent} =
        Components.create_component(scope, %{
          name: "Todos",
          type: "context",
          module_name: "MyApp.Todos"
        })

      {:ok, child} =
        Components.create_component(scope, %{
          name: "Todo",
          type: "schema",
          module_name: "MyApp.Todos.Todo",
          parent_component_id: parent.id
        })

      {:ok, story} =
        Stories.create_story(scope, %{
          ready_for_dev: true,
          title: "Test Story",
          description: "As a user...",
          acceptance_criteria: ["AC1"],
          component_id: parent.id
        })

      write_file(tmp_dir, "lib/my_app/todos.ex", impl_content("MyApp.Todos"))
      write_file(tmp_dir, "lib/my_app/todos/todo.ex", impl_content("MyApp.Todos.Todo"))
      sync!(scope, tmp_dir)

      {story, child}
    end

    test "a container's kickoff edge to its child is emitted once" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)
      {story, child} = parent_and_child(scope, tmp_dir)

      {_nodes, edges} = RequirementGraph.compute_graph(scope)

      kickoff =
        Enum.filter(edges, fn e ->
          e.from == {"story", story.id, "bdd_specs_exist"} and
            match?({"component", id, _} when id == child.id, e.to)
        end)

      assert kickoff == Enum.uniq(kickoff),
             "the graph must not carry the same kickoff edge twice"
    end

    test "the story still reaches the child's work" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)
      {_story, child} = parent_and_child(scope, tmp_dir)

      {_nodes, edges} = RequirementGraph.compute_graph(scope)

      assert Enum.any?(edges, fn e ->
               match?({"component", id, _} when id == child.id, e.to)
             end),
             "suppressing the parent's duplicate must not orphan the child — " <>
               "dropping an edge nothing else emits is how this goes wrong"
    end
  end

  describe "vacuous truth prevention" do
    test "bdd_specs_exist is unsatisfied when no bdd spec files exist" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      component = create_component(scope, "MyApp.Widget", "repository")

      {:ok, story} =
        Stories.create_story(scope, %{
          ready_for_dev: true,
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
      {:ok, component} =
        Components.create_component(scope, %{
          name: "Widget",
          type: "schema",
          module_name: "MyApp.Widget"
        })

      {:ok, story} =
        Stories.create_story(scope, %{
          ready_for_dev: true,
          title: "Test Story",
          description: "As a user...",
          acceptance_criteria: ["AC1"],
          component_id: component.id
        })

      # Write a file so sync detects the component
      write_file(tmp_dir, "lib/my_app/widget.ex", impl_content("MyApp.Widget"))
      sync!(scope, tmp_dir)

      {_nodes, edges} = RequirementGraph.compute_graph(scope)

      # Entry: bdd_specs_exist → component.implementation_file
      entry =
        Enum.find(edges, fn e ->
          e.from == {"story", story.id, "bdd_specs_exist"} and
            e.to == {"component", component.id, "implementation_file"}
        end)

      assert entry,
             "should have entry edge from story.bdd_specs_exist to component.implementation_file"

      # Exit: component.implementation_file → story.ready_for_qa
      # (terminal for schema). The specs-passing gate sits between the
      # component tree and QA, so component terminals land there rather
      # than on qa_complete directly.
      exit_edge =
        Enum.find(edges, fn e ->
          e.from == {"component", component.id, "implementation_file"} and
            e.to == {"story", story.id, "ready_for_qa"}
        end)

      assert exit_edge, "should have exit edge from component terminal to story.ready_for_qa"
    end

    test "creates edges for direct dependencies" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      # Surface component depends on a context
      {:ok, surface} =
        Components.create_component(scope, %{
          name: "TodoListLive",
          type: "live_context",
          module_name: "MyApp.TodoListLive"
        })

      {:ok, context} =
        Components.create_component(scope, %{
          name: "Todos",
          type: "context",
          module_name: "MyApp.Todos"
        })

      {:ok, _dep} =
        Components.create_dependency(scope, %{
          source_component_id: surface.id,
          target_component_id: context.id
        })

      {:ok, story} =
        Stories.create_story(scope, %{
          ready_for_dev: true,
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
      ctx_entry =
        Enum.find(edges, fn e ->
          e.from == {"story", story.id, "bdd_specs_exist"} and
            e.to == {"component", context.id, "implementation_file"}
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

      {:ok, surface} =
        Components.create_component(scope, %{
          name: "TodoListLive",
          type: "live_context",
          module_name: "MyApp.TodoListLive"
        })

      {:ok, context} =
        Components.create_component(scope, %{
          name: "Todos",
          type: "context",
          module_name: "MyApp.Todos"
        })

      {:ok, deep_dep} =
        Components.create_component(scope, %{
          name: "Accounts",
          type: "context",
          module_name: "MyApp.Accounts"
        })

      {:ok, _} =
        Components.create_dependency(scope, %{
          source_component_id: surface.id,
          target_component_id: context.id
        })

      {:ok, _} =
        Components.create_dependency(scope, %{
          source_component_id: context.id,
          target_component_id: deep_dep.id
        })

      {:ok, story} =
        Stories.create_story(scope, %{
          ready_for_dev: true,
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

  describe "discovered components with no file on this checkout are not swept into a story" do
    test "a discovered child of a dependency context, referenced only by that context, is excluded" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      {:ok, surface} =
        Components.create_component(scope, %{
          name: "TodoListLive",
          type: "live_context",
          module_name: "MyApp.TodoListLive"
        })

      {:ok, context} =
        Components.create_component(scope, %{
          name: "Accounts",
          type: "context",
          module_name: "MyApp.Accounts"
        })

      {:ok, _dep} =
        Components.create_dependency(scope, %{
          source_component_id: surface.id,
          target_component_id: context.id
        })

      {:ok, story} =
        Stories.create_story(scope, %{
          ready_for_dev: true,
          title: "Test Story",
          description: "As a user...",
          acceptance_criteria: ["AC1"],
          component_id: surface.id
        })

      write_file(tmp_dir, "lib/my_app/todo_list_live.ex", impl_content("MyApp.TodoListLive"))
      write_file(tmp_dir, "lib/my_app/accounts.ex", impl_content("MyApp.Accounts"))
      sync!(scope, tmp_dir)

      # Simulated the way the real defect arrives: a component row synced
      # into existence by a *different* checkout's files, referenced only
      # by its authored parent, with nothing on this project's own Files
      # records. Created directly, after the real sync above, so this
      # module's own pruning pass never runs against it.
      ghost = create_child_component(scope, "MyApp.Accounts.Ghost", "module", context.id)
      {:ok, ghost} = Components.update_component(scope, ghost, %{provenance: :discovered})

      {_nodes, edges} = RequirementGraph.compute_graph(scope)

      refute Enum.any?(edges, fn e ->
               e.from == {"story", story.id, "bdd_specs_exist"} and
                 e.to == {"component", ghost.id, "implementation_file"}
             end),
             "the story's kickoff must not reach a discovered component with no file on " <>
               "this checkout"

      assert Enum.any?(edges, fn e ->
               e.from == {"story", story.id, "bdd_specs_exist"} and
                 e.to == {"component", context.id, "implementation_file"}
             end),
             "the real, file-backed dependency context must still be reached"
    end
  end

  describe "implementation container edges" do
    test "a context implementation waits for its child implementation" do
      {scope, tmp_dir} = setup_project()
      parent = create_component(scope, "MyApp.Accounts", "context")
      child = create_child_component(scope, "MyApp.Accounts.User", "schema", parent.id)

      {:ok, story} =
        Stories.create_story(scope, %{
          ready_for_dev: true,
          title: "Accounts",
          description: "Accounts work",
          acceptance_criteria: ["accounts work"],
          component_id: parent.id
        })

      sync!(scope, tmp_dir)
      {nodes, edges} = RequirementGraph.compute_graph(scope)

      assert Enum.all?(
               Enum.filter(nodes, &(&1.entity_type == "component")),
               &(&1.name == "implementation_file")
             )

      assert %{
               from: {"component", child.id, "implementation_file"},
               to: {"component", parent.id, "implementation_file"}
             } in edges

      assert %{
               from: {"component", parent.id, "implementation_file"},
               to: {"story", story.id, "ready_for_qa"}
             } in edges
    end

    test "a live context holds only its children's implementation work" do
      {scope, tmp_dir} = setup_project()
      parent = create_component(scope, "MyApp.TodoListLive", "live_context")
      child = create_child_component(scope, "MyApp.TodoListLive.Index", "liveview", parent.id)
      sync!(scope, tmp_dir)
      {nodes, _edges} = RequirementGraph.compute_graph(scope)
      refute Enum.any?(nodes, &(&1.entity_type == "component" and &1.entity_id == parent.id))
      assert find_node(nodes, "component", child.id, "implementation_file")
    end
  end

  describe "qa_complete prerequisites" do
    # Story 1003, revised 2026-09-28: QA now runs against the story's own
    # working copy (story 1108), not against main after a promotion — so
    # `story_promoted` moved from *before* `qa_complete` to *after* it.
    # Promotion records verified work landing; it no longer gates what QA can
    # test. `story_issues_resolved` sits ahead of `qa_complete` instead,
    # straight off `ready_for_qa`: a story's own known issues have to be
    # clear before QA spends a pass on it. Analyzer findings are the promote
    # gate's (28d72f8a), so `problems_resolved` is gone.
    #
    # Whether the copy is actually serving is deliberately not a graph node —
    # a `qa_target_serving` node here was tried and reverted the same day
    # (Harness, session 4298eb): `QaStory` already brings the copy's own app
    # up live as part of starting, and a graph-level refusal that redirected
    # to `PromoteWork` instead would have let `promoted_version` get stamped
    # before `qa_complete` was satisfied. See criterion 1169's spex.
    test "qa_complete waits on issues clearing; story_promoted waits on qa_complete" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      {:ok, story} =
        Stories.create_story(scope, %{
          ready_for_dev: true,
          title: "Test Story",
          description: "As a user...",
          acceptance_criteria: ["AC1"]
        })

      sync!(scope, tmp_dir)

      {_nodes, edges} = RequirementGraph.compute_graph(scope)

      edge? = fn from, to ->
        Enum.any?(edges, fn e ->
          e.from == {"story", story.id, from} and e.to == {"story", story.id, to}
        end)
      end

      assert edge?.("story_issues_triaged", "story_issues_resolved")
      assert edge?.("story_issues_resolved", "ready_for_qa")
      assert edge?.("ready_for_qa", "qa_complete")
      assert edge?.("qa_complete", "story_promoted")
      refute edge?.("ready_for_qa", "story_issues_resolved")

      refute edge?.("story_promoted", "qa_complete"),
             "the old direction — promotion gating QA — must not survive the reorder"

      refute edge?.("ready_for_qa", "story_promoted"),
             "promotion is no longer reached straight off ready_for_qa; it " <>
               "waits on qa_complete now"
    end

    test "qa_complete is not actionable when bdd_specs_exist is unsatisfied" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      {:ok, story} =
        Stories.create_story(scope, %{
          ready_for_dev: true,
          title: "Test Story",
          description: "As a user...",
          acceptance_criteria: ["AC1"]
        })

      sync!(scope, tmp_dir)

      RequirementGraph.recompute(scope)
      actionable = RequirementGraph.next_actionable(scope)

      qa_complete =
        Enum.find(actionable, fn n ->
          n.entity_type == "story" and n.entity_id == story.id and n.name == "qa_complete"
        end)

      refute qa_complete,
             "qa_complete should not be actionable when bdd_specs_exist is unsatisfied"
    end
  end

  describe "field_present details" do
    test "component_linked details include the component_id value" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      component = create_component(scope, "MyApp.Widget", "schema")

      {:ok, story} =
        Stories.create_story(scope, %{
          ready_for_dev: true,
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

  defp setup_project do
    tmp_dir = CodeMySpec.TempFile.owned_dir("test")
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

    scope = %{
      scope
      | active_project: project,
        cwd: tmp_dir,
        environment: Environment.new(:local, tmp_dir)
    }

    # Graph-shape tests need the full spec -> review -> test -> implementation
    # chain; a fresh project defaults to spex and code only.
    {ConfigurationsFixtures.ensure_configuration!(scope), tmp_dir}
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

    {:ok, component} =
      Components.update_component(scope, component, %{parent_component_id: parent_id})

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

    # Three amigos adds a happy_path AND a failure_path criterion.
    # bdd_specs_covered checks every criterion, not just the first, so both
    # need a file (issue 644279a9).
    Enum.each(story.criteria, fn criterion ->
      bdd_path = CodeMySpecSpex.Fixtures.spec_file_path(story, criterion)
      write_file(tmp_dir, bdd_path, bdd_spec_stub(story, criterion))
    end)

    # Insert a DB-backed QA pass attempt. The requirement graph now checks
    # Qa.complete?/2 (DB-driven), not result_complete.md on disk.
    {:ok, _attempt} =
      %QaAttempt{}
      |> QaAttempt.changeset(%{
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
  defp impl_content(module_name) do
    """
    defmodule #{module_name} do
      @moduledoc false
    end
    """
  end
end
