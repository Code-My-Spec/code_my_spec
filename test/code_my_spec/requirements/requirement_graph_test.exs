defmodule CodeMySpec.Requirements.RequirementGraphTest do
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Projects
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers

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

    test "returns component spec requirements when the project chain is fully satisfied" do
      {scope, tmp_dir} = setup_project()

      # Advance the project-level serial chain (project_setup → personas_complete →
      # technical_strategy → architecture_designed → spex_boundary_ready →
      # qa_setup → qa_journey_*). Without this the component-level requirement
      # graph stays clamped behind the project chain.
      kickoff_context =
        ProjectStateFixtures.apply_project_kickoff(%{
          scope: scope,
          environment: scope.environment
        })

      scope = kickoff_context.scope
      persona_id = kickoff_context.persona_id

      # Create a component without a spec, story-linked to satisfy
      # stories_exist + the architecture orphan check.
      {:ok, _component} =
        Components.create_component(scope, %{
          name: "Widget",
          type: "schema",
          module_name: "MyApp.Widget"
        })

      story =
        StoryHelpers.create_and_link(scope, "MyApp.Widget",
          title: "Build the widget",
          description: "As an engineer, I want a Widget so that I can store things.",
          acceptance_criteria: ["widget exists"],
          priority: 5
        )

      # The story-to-component edge requires the story chain (three_amigos
      # → bdd_specs_exist → bdd_specs_passing → qa_complete) to clear before
      # the component's spec_file becomes actionable.
      seed_story_chain_complete(scope, tmp_dir, story, persona_id)

      write_file(tmp_dir, "lib/my_app/widget.ex", "defmodule MyApp.Widget do\nend")
      sync!(scope, tmp_dir)

      actionable = RequirementGraph.next_actionable(scope)
      names = Enum.map(actionable, & &1.name)

      # Component needs a spec (spec_file is first requirement for schema)
      assert "spec_file" in names
    end

    # Issue 5e7ffbd9 reported the graph offering implementation_file for MCP
    # tools before the modules they delegate to existed. The graph does order
    # this correctly — but only through dependency EDGES, which gate
    # actionability outright, not through the priority sort. A dependent
    # component does not sort late; it does not appear at all until what it
    # depends on is done.
    #
    # That is why the reported symptom happened: those components were created
    # without dependency edges, so there was nothing to gate on. This test
    # pins the mechanism that does the work, so a change to actionability
    # can't quietly reintroduce the symptom.
    test "a component that depends on another is not actionable until that one is done" do
      {scope, tmp_dir} = setup_project()

      kickoff_context =
        ProjectStateFixtures.apply_project_kickoff(%{
          scope: scope,
          environment: scope.environment
        })

      scope = kickoff_context.scope
      persona_id = kickoff_context.persona_id

      story =
        StoryHelpers.create_story(scope,
          title: "Agent records a QA result",
          description: "As an agent, I want to submit a QA result so that it is recorded.",
          acceptance_criteria: ["a result is recorded"],
          priority: 1
        )

      # Go through the real architecture flow rather than create_component +
      # create_dependency. Components are file projections, so hand-created
      # ones are dropped by the next sync, and adding a dependency out of band
      # invalidates architecture_designed, which gates all component work.
      proposal =
        CodeMySpec.ArchitectureFixtures.proposal_with_surface_and_context(
          app: "MyApp",
          surface_name: "QaLive",
          surface_description: "Where the agent submits a QA result",
          context_name: "Qa",
          context_description: "QA attempt recording",
          story_id: story.id
        )

      {:ok, _} =
        CodeMySpec.ArchitectureFixtures.with_executed_proposal(
          scope,
          scope.environment,
          proposal
        )

      story = StoryHelpers.fetch(scope, story.id)
      seed_story_chain_complete(scope, tmp_dir, story, persona_id)
      sync!(scope, tmp_dir)

      surface = Components.get_component_by_module_name(scope, "MyAppWeb.QaLive")
      context = Components.get_component_by_module_name(scope, "MyApp.Qa")

      actionable = RequirementGraph.next_actionable(scope)
      component_ids = for n <- actionable, n.entity_type == "component", do: n.entity_id

      assert context.id in component_ids,
             "the depended-on context should be offered first, got: " <>
               inspect(Enum.map(actionable, &{&1.entity_type, &1.name}))

      refute surface.id in component_ids,
             "MyAppWeb.QaLive depends on MyApp.Qa and must not be offered " <>
               "while that context is unbuilt — this is the defect in 5e7ffbd9"
    end

    # Regression guard for the tiering restored in "Restore project requirement
    # tiering in next_actionable". Commit 2d4f928b introduced the early/late
    # project split; 3f7be0c9 collapsed it into a single dead-last tier, and
    # nothing failed — no test asserted the ordering in either direction. That
    # silence is why architecture_designed and issues_triaged sat beneath 719
    # tethered component requirements. This test is the assertion that was
    # missing.
    test "an unsatisfied early project requirement sorts before tethered component work" do
      {scope, tmp_dir} = setup_project()

      # Advance the project chain up to (and including) qa_integration_plan,
      # deliberately stopping short of apply_architecture/1 so
      # architecture_designed is unsatisfied while its only prerequisite
      # (qa_integration_plan) is satisfied — i.e. genuinely actionable.
      kickoff_context =
        %{scope: scope, environment: scope.environment}
        |> ProjectStateFixtures.apply_project_setup_steps()
        |> ProjectStateFixtures.apply_technical_strategy()
        |> ProjectStateFixtures.apply_code_generation()
        |> ProjectStateFixtures.apply_qa_integration_plan()
        |> ProjectStateFixtures.apply_persona()

      scope = kickoff_context.scope

      # Tethered component work: a story with a real priority linked to a
      # component, so the component inherits that priority and lands in the
      # story/component tier rather than being dropped as untethered.
      {:ok, _component} =
        Components.create_component(scope, %{
          name: "Widget",
          type: "schema",
          module_name: "MyApp.Widget"
        })

      StoryHelpers.create_and_link(scope, "MyApp.Widget",
        title: "Build the widget",
        description: "As an engineer, I want a Widget so that I can store things.",
        acceptance_criteria: ["widget exists"],
        priority: 1
      )

      write_file(tmp_dir, "lib/my_app/widget.ex", "defmodule MyApp.Widget do\nend")
      sync!(scope, tmp_dir)

      actionable = RequirementGraph.next_actionable(scope)

      assert "architecture_designed" in Enum.map(actionable, & &1.name),
             "expected architecture_designed to be actionable when its prerequisite is satisfied, got: #{inspect(Enum.map(actionable, &{&1.entity_type, &1.name}))}"

      # Priority 1 on the story is the strongest possible pull for the
      # component tier, so this ordering only holds if project requirements
      # occupy an earlier tier rather than competing on priority.
      first_project_index =
        Enum.find_index(actionable, &(&1.entity_type == "project"))

      first_component_index =
        Enum.find_index(actionable, &(&1.entity_type == "component"))

      assert first_project_index != nil,
             "expected at least one actionable project requirement"

      if first_component_index do
        assert first_project_index < first_component_index,
               "expected project requirements to sort before component work, got: #{inspect(Enum.map(actionable, &{&1.entity_type, &1.name}))}"
      end
    end

    test "the qa journey chain sorts after story and component work" do
      {scope, tmp_dir} = setup_project()

      kickoff_context =
        ProjectStateFixtures.apply_project_kickoff(%{
          scope: scope,
          environment: scope.environment
        })

      scope = kickoff_context.scope

      {:ok, _component} =
        Components.create_component(scope, %{
          name: "Widget",
          type: "schema",
          module_name: "MyApp.Widget"
        })

      StoryHelpers.create_and_link(scope, "MyApp.Widget",
        title: "Build the widget",
        description: "As an engineer, I want a Widget so that I can store things.",
        acceptance_criteria: ["widget exists"],
        priority: 1
      )

      write_file(tmp_dir, "lib/my_app/widget.ex", "defmodule MyApp.Widget do\nend")
      sync!(scope, tmp_dir)

      actionable = RequirementGraph.next_actionable(scope)
      names = Enum.map(actionable, & &1.name)

      # Anchor: there is non-project work in the list, so the ordering
      # assertion below is meaningful rather than vacuous.
      assert Enum.any?(actionable, &(&1.entity_type in ["story", "component"])),
             "expected story or component work to be actionable after kickoff"

      journey_index =
        Enum.find_index(names, &(&1 in ["qa_journey_plan", "qa_journey_execute", "qa_journey_wallaby"]))

      other_index =
        Enum.find_index(actionable, &(&1.entity_type in ["story", "component"]))

      if journey_index do
        assert journey_index > other_index,
               "expected the qa journey chain to sort after story/component work, got: #{inspect(Enum.map(actionable, &{&1.entity_type, &1.name}))}"
      end
    end

    test "story component_linked is blocked when project prerequisites are unsatisfied" do
      {scope, tmp_dir} = setup_project()
      seed_setup(tmp_dir)

      {:ok, _story} =
        Stories.create_story(scope, %{
        ready_for_dev: true,
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

      # Write an impl file so the component survives ComponentSync.cleanup_removed
      # and isn't classified as infrastructure (its path isn't in the seeded
      # infrastructure_paths list).
      File.mkdir_p!(Path.join(tmp_dir, "lib/my_app"))
      File.write!(
        Path.join(tmp_dir, "lib/my_app/widget.ex"),
        "defmodule MyApp.Widget do\nend\n"
      )

      {:ok, _} =
        Components.create_component(scope, %{
          name: "Widget",
          type: "schema",
          module_name: "MyApp.Widget"
        })

      {:ok, _} =
        Stories.create_story(scope, %{
        ready_for_dev: true,
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
        ready_for_dev: true,
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
        ready_for_dev: true,
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

  # Clear the full story-level chain inline. (The LiveView-driven
  # `apply_story_chain_complete` fixture needs a `context.conn`, which
  # this plain-ExUnit test doesn't have.) Mirrors three_amigos →
  # bdd_spec file → DB QA pass attempt → sync.
  defp seed_story_chain_complete(scope, tmp_dir, story, persona_id) do
    :ok =
      ProjectStateFixtures.apply_three_amigos_for_story(scope, story,
        persona_id: persona_id,
        rule_statement: "Rule for #{story.title}"
      )

    # Re-fetch the story so criteria (created during three amigos) are available.
    story = CodeMySpecSpex.StoryHelpers.fetch(scope, story.id)
    [criterion | _] = story.criteria
    bdd_path = CodeMySpec.BddSpecs.spec_file_path(story, criterion)

    bdd_content = """
    defmodule CodeMySpecSpex.Story#{story.id}.Criterion#{criterion.id}Spex do
      use ExUnit.Case, async: true

      test "placeholder" do
        assert true
      end
    end
    """

    write_file(tmp_dir, bdd_path, bdd_content)

    # Insert a DB-backed QA pass attempt directly. The requirement graph
    # now checks Qa.complete?/2 (DB-driven), not result_complete.md on disk.
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

  defp write_file(tmp_dir, relative_path, content) do
    full_path = Path.join(tmp_dir, relative_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
  end
end
