defmodule CodeMySpecSpex.SharedGivens do
  @moduledoc """
  Shared given steps for BDD specifications.

  Import into a spec:

      defmodule CodeMySpecSpex.SomeSpex do
        use CodeMySpecSpex.Case
        import CodeMySpecSpex.SharedGivens

        spex "..." do
          scenario "..." do
            given_ :synced_context_component
            given_ :story_linked_to_component
            given_ :on_configuration_page
            # ...
          end
        end
      end

  Each given ESTABLISHES state and produces keys on `context` for subsequent
  steps. Givens do not assert — assertions about system behavior belong in
  `then_` steps. If setup fails it should surface as a pattern match failure
  or a raise at the point of failure, not as a separate assert.

  ## Defined givens

  - `:synced_context_component` — writes a context spec file into the
    in-memory environment, triggers sync via the /sync LiveView button,
    pattern-matches the resulting component. Produces `context.component`.
  - `:story_linked_to_component` — drives `CreateStory` + `SetStoryComponent`
    MCP tools to create a story and link it to `context.component`.
    Produces `context.story`. Requires `context.component` from a prior given.
  - `:on_configuration_page` — navigates to the project configuration
    LiveView. Produces `context.config_live`.
  - `:bdd_task_started` — drives the real session_start hook + StartTask
    MCP tool to create an active `WriteBddSpecs` task on a story.
    Produces `context.session_id`, `context.task_id`, `context.prompt`,
    and `context.start_response`. Requires `context.story`.
  - `:context_spec_task_started` — drives session_start + start_task for
    the `spec_file` requirement on `context.component` (satisfied by
    `:synced_context_component`'s synced spec file). Gives specs a
    main_agent/automatic task whose evaluation trivially passes, so
    the spec can observe pipeline behavior without evaluator noise.
    Produces `context.session_id`. Requires `context.component`.
  - `:credo_available` — plants `deps/credo` under `context.scope.cwd`
    so the Credo analyzer's availability check passes. Pair with a
    cassette that replays `mix credo` output.
  - `:persona_exists` — drives the `CreatePersona` MCP tool against the
    active scope to create a project-scoped persona. Produces
    `context.persona_slug` and `context.persona_id`.
  - `:persona_research_task_started` — drives session_start + start_task
    for the `personas_complete` requirement on the active project.
    Produces `context.session_id`.
  - `:persona_research_prompt` — same as `:persona_research_task_started`
    but flattens the start_task response into a single prompt text string.
    Produces `context.prompt` and `context.session_id`. Use when a spec
    asserts on prompt content rather than pipeline side effects.
  - `:technical_strategy_task_started` — drives session_start + start_task
    for the `technical_strategy` requirement on the active project. The
    start_task call triggers `TechnicalStrategy.command/2`, which writes
    missing pre-made ADRs and returns the session prompt. Produces
    `context.session_id`, `context.task_id`, and `context.prompt`.
  - `:code_generation_task_started` — drives session_start + start_task
    for the `code_generation` requirement on the active project. Returns
    the prompt the agent receives so specs can assert on its content
    or pass it forward into evaluate_task scenarios. Produces
    `context.session_id`, `context.task_id`, and `context.prompt`.
  - `:qa_integration_plan_task_started` — drives session_start + start_task
    for the `qa_integration_plan` requirement on the active project.
    Mirror of the code_generation given for the integration-credentials
    flow. Produces `context.session_id`, `context.task_id`, and
    `context.prompt`.
  - `:qa_setup_task_started` — drives session_start + start_task for the
    `qa_setup` requirement on the active project. Returns the planning
    prompt so specs can assert on its content or pass the task_id forward
    into evaluate_task scenarios. Produces `context.session_id`,
    `context.task_id`, and `context.prompt`.
  - `:three_amigos_task_started` — drives session_start + start_task for
    the `three_amigos_complete` requirement on `context.story`. Mirror of
    `:persona_research_task_started` for the per-story Three Amigos node.
    Produces `context.session_id` and `context.task_id`. Requires
    `context.story` from a prior given.
  - `:fix_issues_task_started` — drives session_start + start_task for
    the `issues_resolved` requirement on the active project. Returns the
    fix-issues prompt so specs can assert on its content or pass the
    task_id forward into evaluate_task scenarios. Produces
    `context.session_id`, `context.task_id`, and `context.prompt`.
  - `:registered_user_with_magic_link` — drives the `/users/register`
    LiveView submit, captures the magic-link email through the Swoosh
    test adapter, and extracts the magic-link URL from the email body.
    Produces `context.registered_email` and `context.magic_link_url`.
    Uses the main `CodeMySpecWeb.Endpoint` (auth lives there, not on
    the local web).
  - `:empty_state_user_on_onboarding` — chains
    `:registered_user_with_magic_link`, follows the magic-link URL to
    log the user in, then drives the inline create-account form on
    /app (story 606's first onboarding step) so the user has an active
    account before subsequent steps inspect the project-name form.
    Re-mounts /app after the form submit so `context.view` /
    `context.html` reflect the post-account state, sitting on the
    project-name step. Produces `context.conn`, `context.view`, and
    `context.html`. Use this in any story-603/604/605 spec that needs
    to interact with the project-name form.

  Add new shared givens only after a third spec duplicates setup.
  """

  use SexySpex.Givens

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.BddRules.Tools.AddRule
  alias CodeMySpec.McpServers.BddRules.Tools.AddScenario
  alias CodeMySpec.McpServers.Personas.Tools.CreatePersona
  alias CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.StoryHelpers

  @endpoint CodeMySpecLocalWeb.Endpoint

  @component_module_name "ExampleContext"
  @spec_path ".code_my_spec/spec/example_context.spec.md"
  @impl_path "lib/example_context.ex"

  # Writes a context spec file into the in-memory environment, triggers the
  # real sync pipeline via the /sync LiveView button, and fetches the
  # component that sync derived.
  register_given :synced_context_component, context do
    scope = context.scope
    env = context.environment

    :ok = Environments.write_file(env, @spec_path, spec_file_content())
    :ok = Environments.write_file(env, @impl_path, impl_file_content())

    {:ok, sync_live, _html} =
      live(context.conn, "/app/projects/#{context.project.id}/files")

    sync_live
    |> element("button[phx-click='sync']")
    |> render_click()

    %_{} =
      component =
      Fixtures.get_component_by_module_name(scope, @component_module_name)

    {:ok, Map.put(context, :component, component)}
  end

  # Like :synced_context_component, but layered on top of a fully-satisfied
  # project chain (`FullSatisfactionFixtures.apply/1`) and with a story
  # linked to ExampleContext so it isn't an orphan context. The kickoff
  # edge for the new story is also cleared (three_amigos + bdd_specs_exist
  # satisfied) so ExampleContext's chain isn't clamped.
  #
  # Use this when a spec needs to exercise the agent surface
  # (`get_next_requirement`) past the architecture_designed gate while
  # still having ExampleContext's downstream nodes (review_file,
  # implementation_file, tests, etc.) be the actionable frontier.
  #
  # Produces: `context.component`, `context.example_story`, plus all keys
  # from `:fully_satisfied_project` (scope, environment, project, story
  # for Reservations, persona_slug, persona_id).
  register_given :synced_context_in_satisfied_project, context do
    context = FullSatisfactionFixtures.apply(context)

    env = context.environment
    scope = context.scope

    :ok = Environments.write_file(env, @spec_path, spec_file_content())
    :ok = Environments.write_file(env, @impl_path, impl_file_content())

    {:ok, sync_live, _html} =
      live(context.conn, "/app/projects/#{context.project.id}/files")

    sync_live |> element("button[phx-click='sync']") |> render_click()

    %_{} =
      component =
      Fixtures.get_component_by_module_name(scope, @component_module_name)

    story =
      StoryHelpers.create_and_link(scope, @component_module_name,
        title: "Example context story",
        description: "Manage the example context",
        acceptance_criteria: ["Example works"],
        priority: 1
      )

    frame = %Frame{assigns: %{current_scope: scope}}

    {:reply, _response, _frame} =
      LinkPersonaToStory.execute(
        %{persona_id: context.persona_id, story_id: story.id},
        frame
      )

    rule_statement = "Example context behaves as expected"

    {:reply, _response, _frame} =
      AddRule.execute(%{story_id: story.id, statement: rule_statement}, frame)

    {:reply, _response, _frame} =
      AddScenario.execute(
        %{
          story_id: story.id,
          rule_statement: rule_statement,
          kind: "happy_path",
          title: "Happy path",
          body:
            "Given the user opens the page\nWhen they click the button\nThen the action succeeds"
        },
        frame
      )

    {:reply, _response, _frame} =
      AddScenario.execute(
        %{
          story_id: story.id,
          rule_statement: rule_statement,
          kind: "failure_path",
          title: "Failure path",
          body:
            "Given the user is logged out\nWhen they click the button\nThen they are redirected to login"
        },
        frame
      )

    story = StoryHelpers.fetch(scope, story.id)
    [criterion | _] = story.criteria

    bdd_path = Fixtures.spec_file_path(story, criterion)

    bdd_content = """
    defmodule CodeMySpecSpex.Story#{story.id}.Criterion#{criterion.id}Spex do
      @moduledoc \"\"\"
      Story #{story.id} — #{story.title}
      Criterion #{criterion.id} — #{criterion.description}
      \"\"\"

      use CodeMySpecSpex.Case

      spex "#{story.title}" do
        scenario "the criterion holds" do
          then_ "the placeholder assertion passes" do
            assert true
            :ok
          end
        end
      end
    end
    """

    :ok = Environments.write_file(env, bdd_path, bdd_content)

    {:ok, sync_live, _html} =
      live(context.conn, "/app/projects/#{context.project.id}/files")

    sync_live |> element("button[phx-click='sync']") |> render_click()

    {:ok, Map.merge(context, %{component: component, example_story: story})}
  end

  # Creates a story and links it to the component via the same MCP tools the
  # agent uses in production (CreateStory + SetStoryComponent), keeping setup
  # on the surface the harness drives.
  register_given :story_linked_to_component, context do
    linked_story =
      StoryHelpers.create_and_link(context.scope, context.component.module_name,
        title: "Example user story",
        description: "An example for BDD specs",
        acceptance_criteria: ["Example acceptance criterion"]
      )

    {:ok, Map.put(context, :story, linked_story)}
  end

  # The engineer has opened the project configuration page.
  register_given :on_configuration_page, context do
    {:ok, config_live, _html} =
      live(context.conn, "/app/projects/#{context.project.id}/configuration")

    {:ok, Map.put(context, :config_live, config_live)}
  end

  # Plants an empty `deps/credo` directory inside the stub working
  # directory so `CodeMySpec.StaticAnalysis.Analyzers.Credo.available?/1`
  # returns true for this spec. Without this, credo is unavailable in
  # the memfs-backed spec environment and the pipeline silently
  # no-ops credo. Pair with a cassette that replays the actual
  # `mix credo` output.
  register_given :credo_available, context do
    File.mkdir_p!(Path.join([context.scope.cwd, "deps", "credo"]))
    {:ok, context}
  end

  # Like :synced_context_component but produces a liveview-typed
  # component so the liveview_graph applies. Specs that need a :self
  # :sub_agent requirement (e.g. `test_spec_alignment`) can start a
  # task on this component. Produces `context.liveview_component`.
  register_given :synced_liveview_component, context do
    scope = context.scope
    env = context.environment

    spec_path = ".code_my_spec/spec/example_context_web/dashboard_live.spec.md"
    impl_path = "lib/example_context_web/live/dashboard_live.ex"

    :ok =
      Environments.write_file(env, spec_path, """
      # DashboardLive

      An example liveview for BDD specs.

      ## Type

      liveview
      """)

    :ok =
      Environments.write_file(env, impl_path, """
      defmodule ExampleContextWeb.DashboardLive do
        @moduledoc false
      end
      """)

    {:ok, sync_live, _html} =
      live(context.conn, "/app/projects/#{context.project.id}/files")

    sync_live |> element("button[phx-click='sync']") |> render_click()

    %_{} =
      component =
      Fixtures.get_component_by_module_name(scope, "ExampleContextWeb.DashboardLive")

    {:ok, Map.put(context, :liveview_component, component)}
  end

  # Drives the real POST /api/hooks/session-start hook and the
  # start_task MCP tool to create an active main_agent/automatic task
  # on `context.component`. Uses the context_graph's :parent-scoped
  # `spec_file` requirement — already satisfied because
  # :synced_context_component wrote and synced the spec file — so
  # TaskEvaluator passes via RequirementCalculator with no extra
  # artifacts needed.
  register_given :context_spec_task_started, context do
    session_id = "spex-#{System.unique_integer([:positive])}"

    post(
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
      |> Plug.Conn.put_req_header("content-type", "application/json"),
      "/api/hooks/session-start",
      %{"session_id" => session_id}
    )
    |> Phoenix.ConnTest.json_response(200)

    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, _response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "spec_file",
          entity_type: "component",
          entity_id: to_string(context.component.id),
          session_id: session_id
        },
        frame
      )

    {:ok, Map.put(context, :session_id, session_id)}
  end

  # The agent has signalled SessionStart and called the start_task MCP tool
  # for the "bdd_specs_exist" requirement on `context.story`. This is the
  # real contract the harness drives — we post to the same HTTP hook and
  # invoke the same MCP tool module, so the pipeline sees a real active
  # `WriteBddSpecs` task whose `analyzers/0` returns `[:spex_stale]`.
  # Captures `session_id`, `task_id`, and `prompt` so specs can drive
  # `evaluate_task` directly or assert on prompt content.
  register_given :bdd_task_started, context do
    session_id = "spex-#{System.unique_integer([:positive])}"

    post(
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
      |> Plug.Conn.put_req_header("content-type", "application/json"),
      "/api/hooks/session-start",
      %{"session_id" => session_id}
    )
    |> Phoenix.ConnTest.json_response(200)

    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "bdd_specs_exist",
          entity_type: "story",
          entity_id: to_string(context.story.id),
          session_id: session_id
        },
        frame
      )

    prompt = flatten_tool_response(response)

    {:ok,
     Map.merge(context, %{
       session_id: session_id,
       task_id: extract_task_id(response),
       prompt: prompt,
       start_response: response
     })}
  end

  # The PM has created a persona on the active project and linked it to
  # at least one story on that project. Personas need
  # a story link to count toward personas_complete, so this given bundles
  # both actions — if a spec needs an unlinked persona it should drive
  # CreatePersona directly inline.
  #
  # Drives the real CreatePersona and LinkPersonaToStory MCP tools — the
  # same contract the agent uses in production. The persona id is parsed
  # from the CreatePersona response footer rather than queried out of the
  # Personas context, keeping spex on the agent surface only. The story
  # is fixtured via the bridge (stories arrive from server sync in
  # production — using the bridge here matches that pattern).
  register_given :persona_exists, context do
    frame = %Frame{assigns: %{current_scope: context.scope}}
    # Unique per invocation so a spex block with multiple scenarios
    # doesn't collide on a single shared slug. CreatePersona enforces
    # uniqueness; without this, a second scenario in the same spex
    # block crashes with a stale id and downstream parse failures.
    unique = System.unique_integer([:positive])
    persona_slug = "founder-#{unique}"

    {:reply, create_response, _frame} =
      CreatePersona.execute(
        %{
          slug: persona_slug,
          name: "Founder #{unique}",
          headline: "Solo founder shipping a product without hiring"
        },
        frame
      )

    persona_id = extract_persona_id(create_response)

    # Three Amigos requires the story to be linked to a surface
    # component (component_linked → three_amigos_complete in the
    # story chain), so set up a synced surface and link the story
    # to it. Use a leaf-typed liveview so we don't spin up a
    # context's orchestrated requirement chain (which would
    # eclipse three_amigos_complete in the actionable list).
    surface_module = "ExampleSurfaceLive#{unique}"
    surface_spec_path = ".code_my_spec/spec/example_surface_live_#{unique}.spec.md"
    surface_impl_path = "lib/example_surface_live_#{unique}.ex"

    :ok =
      Environments.write_file(
        context.environment,
        surface_spec_path,
        CodeMySpecSpex.GraphContentFixtures.liveview_spec(surface_module, dependencies: [])
      )

    :ok =
      Environments.write_file(
        context.environment,
        surface_impl_path,
        CodeMySpecSpex.GraphContentFixtures.impl_file(surface_module)
      )

    {:ok, sync_live, _html} =
      live(context.conn, "/app/projects/#{context.project.id}/files")

    sync_live |> element("button[phx-click='sync']") |> render_click()

    component =
      CodeMySpecSpex.Fixtures.get_component_by_module_name(context.scope, surface_module)

    story =
      StoryHelpers.create_and_link(context.scope, surface_module,
        title: "Persona-linked story",
        description: "Story used to link the persona onto the active project.",
        acceptance_criteria: ["Persona is linked to a story on the active project"]
      )

    {:reply, _link_response, _frame} =
      LinkPersonaToStory.execute(
        %{persona_id: persona_id, story_id: story.id},
        frame
      )

    {:ok,
     Map.merge(context, %{
       persona_slug: persona_slug,
       persona_id: persona_id,
       component: component,
       story: story
     })}
  end

  # The agent has signalled SessionStart and called start_task for the
  # `personas_complete` requirement on the active project. Same shape as
  # :context_spec_task_started / :bdd_task_started — drives the real hook
  # + MCP call so the pipeline sees a live `PersonaResearch` task.
  # Captures the active task id from the session so specs can call
  # `evaluate_task` against it (personas_complete is manual-validation).
  register_given :persona_research_task_started, context do
    session_id = "spex-#{System.unique_integer([:positive])}"

    post(
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
      |> Plug.Conn.put_req_header("content-type", "application/json"),
      "/api/hooks/session-start",
      %{"session_id" => session_id}
    )
    |> Phoenix.ConnTest.json_response(200)

    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "personas_complete",
          entity_type: "project",
          entity_id: to_string(context.project.id),
          session_id: session_id
        },
        frame
      )

    {:ok,
     Map.merge(context, %{session_id: session_id, task_id: extract_task_id(response)})}
  end

  # Drives session_start + start_task and returns the prompt text so specs
  # can assert directly on the instructions the agent receives. Use this
  # when a spec tests static prompt content (e.g., "the prompt tells the
  # agent to X") rather than pipeline side effects.
  register_given :persona_research_prompt, context do
    session_id = "spex-#{System.unique_integer([:positive])}"

    post(
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
      |> Plug.Conn.put_req_header("content-type", "application/json"),
      "/api/hooks/session-start",
      %{"session_id" => session_id}
    )
    |> Phoenix.ConnTest.json_response(200)

    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "personas_complete",
          entity_type: "project",
          entity_id: to_string(context.project.id),
          session_id: session_id
        },
        frame
      )

    prompt =
      case response do
        %{content: parts} when is_list(parts) ->
          Enum.map_join(parts, "\n", fn
            %{text: t} -> t
            %{"text" => t} -> t
            o -> inspect(o)
          end)

        other ->
          inspect(other)
      end

    {:ok, Map.merge(context, %{session_id: session_id, prompt: prompt})}
  end

  # The agent has signalled SessionStart and called start_task for the
  # `technical_strategy` requirement on the active project. Same shape as
  # the other *_task_started givens — drives the real hook + MCP call so
  # the pipeline sees a live `TechnicalStrategy` task. start_task's
  # handler runs `command/2`, which writes missing pre-made ADRs to the
  # env as a side effect and returns the prompt text.
  register_given :technical_strategy_task_started, context do
    session_id = "spex-#{System.unique_integer([:positive])}"

    post(
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
      |> Plug.Conn.put_req_header("content-type", "application/json"),
      "/api/hooks/session-start",
      %{"session_id" => session_id}
    )
    |> Phoenix.ConnTest.json_response(200)

    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "technical_strategy",
          entity_type: "project",
          entity_id: to_string(context.project.id),
          session_id: session_id
        },
        frame
      )

    prompt = flatten_tool_response(response)

    {:ok,
     Map.merge(context, %{
       session_id: session_id,
       task_id: extract_task_id(response),
       prompt: prompt,
       start_response: response
     })}
  end

  # The agent has signalled SessionStart and called start_task for the
  # `code_generation` requirement on the active project. start_task runs
  # `CodeGeneration.command/2`, which returns the orchestration prompt
  # (no side effects on disk — code_generation is a pure prompt builder).
  register_given :code_generation_task_started, context do
    session_id = "spex-#{System.unique_integer([:positive])}"

    post(
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
      |> Plug.Conn.put_req_header("content-type", "application/json"),
      "/api/hooks/session-start",
      %{"session_id" => session_id}
    )
    |> Phoenix.ConnTest.json_response(200)

    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "code_generation",
          entity_type: "project",
          entity_id: to_string(context.project.id),
          session_id: session_id
        },
        frame
      )

    prompt = flatten_tool_response(response)

    {:ok,
     Map.merge(context, %{
       session_id: session_id,
       task_id: extract_task_id(response),
       prompt: prompt,
       start_response: response
     })}
  end

  # The agent has signalled SessionStart and called start_task for the
  # `three_amigos_complete` requirement on `context.story`. Same shape as
  # the other *_task_started givens — drives the real hook + MCP call so
  # the pipeline sees a live `ThreeAmigos` task.
  register_given :three_amigos_task_started, context do
    session_id = "spex-#{System.unique_integer([:positive])}"

    post(
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
      |> Plug.Conn.put_req_header("content-type", "application/json"),
      "/api/hooks/session-start",
      %{"session_id" => session_id}
    )
    |> Phoenix.ConnTest.json_response(200)

    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "three_amigos_complete",
          entity_type: "story",
          entity_id: to_string(context.story.id),
          session_id: session_id
        },
        frame
      )

    {:ok,
     Map.merge(context, %{session_id: session_id, task_id: extract_task_id(response)})}
  end

  # The agent has signalled SessionStart and called start_task for the
  # `issues_resolved` requirement on the active project. start_task runs
  # `FixIssues.command/2`, which reads accepted issues from the DB and
  # returns the fix-issues prompt. issues_resolved is manual-validation
  # so the task stays open for evaluate_task to drive in `when_` steps.
  register_given :fix_issues_task_started, context do
    session_id = "spex-#{System.unique_integer([:positive])}"

    post(
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
      |> Plug.Conn.put_req_header("content-type", "application/json"),
      "/api/hooks/session-start",
      %{"session_id" => session_id}
    )
    |> Phoenix.ConnTest.json_response(200)

    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "issues_resolved",
          entity_type: "project",
          entity_id: to_string(context.project.id),
          session_id: session_id
        },
        frame
      )

    prompt = flatten_tool_response(response)

    {:ok,
     Map.merge(context, %{
       session_id: session_id,
       task_id: extract_task_id(response),
       prompt: prompt,
       start_response: response
     })}
  end

  # The agent has signalled SessionStart and called start_task for the
  # `qa_setup` requirement on the active project. start_task runs
  # `QaSetup.command/2`, which globs `lib/*_web/router.ex`, lists existing
  # qa seed scripts and helper scripts, and returns the planning prompt.
  # qa_setup is manual-validation so the task stays open for evaluate_task
  # to drive in `when_` steps.
  register_given :qa_setup_task_started, context do
    session_id = "spex-#{System.unique_integer([:positive])}"

    post(
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
      |> Plug.Conn.put_req_header("content-type", "application/json"),
      "/api/hooks/session-start",
      %{"session_id" => session_id}
    )
    |> Phoenix.ConnTest.json_response(200)

    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "qa_setup",
          entity_type: "project",
          entity_id: to_string(context.project.id),
          session_id: session_id
        },
        frame
      )

    prompt = flatten_tool_response(response)

    {:ok,
     Map.merge(context, %{
       session_id: session_id,
       task_id: extract_task_id(response),
       prompt: prompt,
       start_response: response
     })}
  end

  # The agent has signalled SessionStart and called start_task for the
  # `qa_integration_plan` requirement on the active project. start_task
  # runs `QaIntegrationPlan.command/2`, which returns the orchestration
  # prompt (no side effects on disk — qa_integration_plan is a pure
  # prompt builder).
  register_given :qa_integration_plan_task_started, context do
    session_id = "spex-#{System.unique_integer([:positive])}"

    post(
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
      |> Plug.Conn.put_req_header("content-type", "application/json"),
      "/api/hooks/session-start",
      %{"session_id" => session_id}
    )
    |> Phoenix.ConnTest.json_response(200)

    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "qa_integration_plan",
          entity_type: "project",
          entity_id: to_string(context.project.id),
          session_id: session_id
        },
        frame
      )

    prompt = flatten_tool_response(response)

    {:ok,
     Map.merge(context, %{
       session_id: session_id,
       task_id: extract_task_id(response),
       prompt: prompt,
       start_response: response
     })}
  end

  # The agent has signalled SessionStart and called start_task for the
  # `spex_boundary_ready` requirement on the active project. start_task
  # runs `SpexBoundaryReady.command/2`, which returns the orchestration
  # prompt (no side effects on disk). Manual-validation task: stays open
  # for evaluate_task to drive in `when_` steps.
  register_given :spex_boundary_ready_task_started, context do
    session_id = "spex-#{System.unique_integer([:positive])}"

    post(
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
      |> Plug.Conn.put_req_header("content-type", "application/json"),
      "/api/hooks/session-start",
      %{"session_id" => session_id}
    )
    |> Phoenix.ConnTest.json_response(200)

    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "spex_boundary_ready",
          entity_type: "project",
          entity_id: to_string(context.project.id),
          session_id: session_id
        },
        frame
      )

    prompt = flatten_tool_response(response)

    {:ok,
     Map.merge(context, %{
       session_id: session_id,
       task_id: extract_task_id(response),
       prompt: prompt,
       start_response: response
     })}
  end

  # The visitor has registered through the public registration LiveView and
  # a magic-link email is sitting in the test mailbox. Drives the real
  # /users/register form submit (CodeMySpecWeb endpoint, not local), captures
  # the sent email through Swoosh's test adapter, and extracts the magic-link
  # URL from the email body so subsequent `when_` steps can hit the same
  # endpoint a real user's browser would.
  register_given :registered_user_with_magic_link, context do
    email = "spex-#{System.unique_integer([:positive])}@example.com"

    # Dispatch through the main web endpoint explicitly — the auth routes
    # live on CodeMySpecWeb, but this module's @endpoint is the local one,
    # so we can't rely on `live/2`'s implicit `get/2` macro to pick the
    # right endpoint. `dispatch/4` lets us name it.
    mounted_conn =
      Phoenix.ConnTest.dispatch(
        Phoenix.ConnTest.build_conn(),
        CodeMySpecWeb.Endpoint,
        :get,
        "/users/register"
      )

    {:ok, view, _html} = Phoenix.LiveViewTest.live(mounted_conn)

    view
    |> Phoenix.LiveViewTest.form("#registration_form", user: %{email: email})
    |> Phoenix.LiveViewTest.render_submit()

    sent_email =
      receive do
        {:email, %Swoosh.Email{} = mail} -> mail
      after
        500 -> raise "expected magic-link email to be delivered for #{email}"
      end

    true = Enum.any?(sent_email.to, fn {_name, addr} -> addr == email end)

    magic_link_url = extract_magic_link_url!(sent_email)

    {:ok, Map.merge(context, %{registered_email: email, magic_link_url: magic_link_url})}
  end

  # The visitor has registered through the public registration LiveView,
  # clicked their magic link (so the user is now confirmed and logged in),
  # named their personal account through the dashboard's create-account
  # form, and is sitting on /app with a connected LiveView socket
  # showing the project-name step. Subsequent `when_` / `then_` steps
  # interact with `context.view` (LiveView) or assert against
  # `context.html` (initial render).
  register_given :empty_state_user_on_onboarding, context do
    %{magic_link_url: magic_link_url} = context

    auth_path = URI.parse(magic_link_url).path

    # Magic-link confirm logs the user in. No account is provisioned
    # by the auth flow — account creation is an explicit first
    # onboarding step.
    auth_conn =
      Phoenix.ConnTest.dispatch(
        Phoenix.ConnTest.build_conn(),
        CodeMySpecWeb.Endpoint,
        :get,
        auth_path
      )

    # Mount onboarding while the user has zero accounts — the LV
    # shows the create-account form. Submit it via the LV so the
    # account + member + active-account preference are written
    # through the same surface a real user uses.
    account_form_conn =
      Phoenix.ConnTest.dispatch(
        Phoenix.ConnTest.recycle(auth_conn),
        CodeMySpecWeb.Endpoint,
        :get,
        "/app"
      )

    {:ok, account_view, _html} = Phoenix.LiveViewTest.live(account_form_conn)

    account_view
    |> Phoenix.LiveViewTest.form("#account_form", account: %{name: "Personal"})
    |> Phoenix.LiveViewTest.render_submit()

    # Re-mount /app now that the active account is set —
    # the LV is in the project-name step that downstream specs assert on.
    onboarding_conn =
      Phoenix.ConnTest.dispatch(
        Phoenix.ConnTest.recycle(account_form_conn),
        CodeMySpecWeb.Endpoint,
        :get,
        "/app"
      )

    {:ok, view, html} = Phoenix.LiveViewTest.live(onboarding_conn)

    {:ok, Map.merge(context, %{conn: onboarding_conn, view: view, html: html})}
  end

  # -- Content helpers --

  defp extract_magic_link_url!(%Swoosh.Email{text_body: body}) when is_binary(body) do
    case Regex.run(~r{https?://\S+/users/log-in/[^\s.,;:!?\"'>)]+}, body) do
      [url] -> url
      _ -> raise "could not extract magic-link URL from email body: #{inspect(body)}"
    end
  end

  defp flatten_tool_response(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      other -> inspect(other)
    end)
  end

  defp flatten_tool_response(%{text: text}), do: text
  defp flatten_tool_response(other), do: inspect(other)

  # Pulls the task id out of a StartTask MCP response. Tasks.TasksMapper
  # embeds it in a footer line: `Task ID: \`<uuid>\``. Parsing the
  # surface response keeps spex specs from reaching into the Sessions
  # context to find the active task.
  defp extract_task_id(response) do
    case Regex.run(~r/Task ID: `([^`]+)`/, flatten_tool_response(response)) do
      [_, task_id] -> task_id
      _ -> nil
    end
  end

  # Pulls the persona id out of a CreatePersona MCP response.
  # PersonasMapper.persona_response writes
  # `(slug: \`...\`, id: \`<uuid>\`)` on the first line; the regex
  # anchors on `\bid: ` to skip over the later `persona_id` mention in
  # the next-steps section.
  defp extract_persona_id(response) do
    case Regex.run(~r/\bid: `([^`]+)`/, flatten_tool_response(response)) do
      [_, persona_id] -> persona_id
      _ -> nil
    end
  end

  defp spec_file_content do
    """
    # ExampleContext

    ## Type

    context

    An example context for BDD specs.

    ## Functions

    ### noop/0

    Returns `:ok`.

    ```elixir
    @spec noop() :: :ok
    ```

    ## Dependencies

    - None

    ## Components

    ### ExampleContext.Noop

    Placeholder child module.
    """
  end

  defp impl_file_content do
    """
    defmodule ExampleContext do
      @moduledoc false
    end
    """
  end
end
