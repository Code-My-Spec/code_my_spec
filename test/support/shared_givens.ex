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
  - `:story_linked_to_component` — creates an unlinked story (arrives from
    server sync in production), then links it to `context.component` via
    `Stories.set_story_component`. Produces `context.story`. Requires
    `context.component` from a prior given.
  - `:on_configuration_page` — navigates to the project configuration
    LiveView. Produces `context.config_live`.
  - `:bdd_task_started` — drives the real session_start hook + StartTask
    MCP tool to create an active `WriteBddSpecs` task on a story.
    Produces `context.session_id`. Requires `context.story` from
    `:story_linked_to_component`.
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
    active scope to create an account-scoped persona. Produces
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
    /app/onboarding (story 606's first onboarding step) so the user
    has an active account before subsequent steps inspect the
    project-name form. Re-mounts /app/onboarding after the form
    submit so `context.view` / `context.html` reflect the post-account
    state. Produces `context.conn`, `context.view`, and `context.html`.
    Use this in any story-603/604/605 spec that needs to interact with
    the project-name form.

  Add new shared givens only after a third spec duplicates setup.
  """

  use SexySpex.Givens

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Personas.Tools.CreatePersona
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

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
      live(context.conn, "/projects/#{context.project.name}/sync")

    sync_live
    |> element("button[phx-click='sync']")
    |> render_click()

    %_{} =
      component =
      Fixtures.get_component_by_module_name(scope, @component_module_name)

    {:ok, Map.put(context, :component, component)}
  end

  # Creates an unlinked story (matches production flow — stories arrive from
  # server sync with no component_id), then links it to the component via
  # the real linkage API.
  register_given :story_linked_to_component, context do
    scope = context.scope
    component = context.component

    story =
      Fixtures.story_fixture(scope,
        title: "Example user story",
        description: "An example for BDD specs"
      )

    {:ok, linked_story} = Fixtures.set_story_component(scope, story, component.id)

    {:ok, Map.put(context, :story, linked_story)}
  end

  # The engineer has opened the project configuration page.
  register_given :on_configuration_page, context do
    {:ok, config_live, _html} =
      live(context.conn, "/projects/#{context.project.name}/configuration")

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
      live(context.conn, "/projects/#{context.project.name}/sync")

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

    {:reply, _response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "bdd_specs_exist",
          entity_type: "story",
          entity_id: to_string(context.story.id),
          session_id: session_id
        },
        frame
      )

    {:ok, Map.put(context, :session_id, session_id)}
  end

  # The PM has created a persona through the account library surface and
  # linked it to at least one story on the active project. Personas need
  # a story link to count toward personas_complete, so this given bundles
  # both actions — if a spec needs an unlinked persona it should drive
  # CreatePersona directly inline.
  #
  # Drives the real CreatePersona MCP tool against the active scope so the
  # personas row originates through the same contract the agent uses in
  # production. The story is fixtured via the bridge (stories arrive from
  # server sync in production — using the bridge here matches that pattern).
  register_given :persona_exists, context do
    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, _response, _frame} =
      CreatePersona.execute(
        %{
          slug: "founder",
          name: "Founder",
          headline: "Solo founder shipping a product without hiring"
        },
        frame
      )

    persona = CodeMySpec.Personas.get_persona_by_slug(context.scope, "founder")

    story =
      Fixtures.story_fixture(context.scope,
        title: "Persona-linked story",
        description: "Story used to link the persona onto the active project."
      )

    {:ok, _} =
      CodeMySpec.Personas.link_persona_to_story(context.scope, persona.id, story.id)

    {:ok,
     Map.merge(context, %{
       persona_slug: persona.slug,
       persona_id: persona.id,
       persona: persona,
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

    {:reply, _response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "personas_complete",
          entity_type: "project",
          entity_id: to_string(context.project.id),
          session_id: session_id
        },
        frame
      )

    session = CodeMySpec.Sessions.get_by_external_id(context.scope, session_id)
    task = CodeMySpec.Sessions.Session.active_task(session)

    {:ok, Map.merge(context, %{session_id: session_id, task_id: task && task.id})}
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

    session = CodeMySpec.Sessions.get_by_external_id(context.scope, session_id)
    task = CodeMySpec.Sessions.Session.active_task(session)

    {:ok,
     Map.merge(context, %{
       session_id: session_id,
       task_id: task && task.id,
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

    session = CodeMySpec.Sessions.get_by_external_id(context.scope, session_id)
    task = CodeMySpec.Sessions.Session.active_task(session)

    {:ok,
     Map.merge(context, %{
       session_id: session_id,
       task_id: task && task.id,
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

    {:reply, _response, _frame} =
      StartTask.execute(
        %{
          requirement_name: "three_amigos_complete",
          entity_type: "story",
          entity_id: to_string(context.story.id),
          session_id: session_id
        },
        frame
      )

    session = CodeMySpec.Sessions.get_by_external_id(context.scope, session_id)
    task = CodeMySpec.Sessions.Session.active_task(session)

    {:ok, Map.merge(context, %{session_id: session_id, task_id: task && task.id})}
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

    session = CodeMySpec.Sessions.get_by_external_id(context.scope, session_id)
    task = CodeMySpec.Sessions.Session.active_task(session)

    {:ok,
     Map.merge(context, %{
       session_id: session_id,
       task_id: task && task.id,
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

    session = CodeMySpec.Sessions.get_by_external_id(context.scope, session_id)
    task = CodeMySpec.Sessions.Session.active_task(session)

    {:ok,
     Map.merge(context, %{
       session_id: session_id,
       task_id: task && task.id,
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
  # clicked their magic link (so the user is now confirmed and the personal
  # account / member / preference rows have all been provisioned), and is
  # sitting on /app/onboarding with a connected LiveView socket. Subsequent
  # `when_` / `then_` steps interact with `context.view` (LiveView) or
  # assert against `context.html` (initial render).
  register_given :empty_state_user_on_onboarding, context do
    %{magic_link_url: magic_link_url} = context

    auth_path = URI.parse(magic_link_url).path

    # Magic-link confirm logs the user in. No account is provisioned
    # by the auth flow anymore — story 606 made account creation an
    # explicit first onboarding step.
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
        "/app/onboarding"
      )

    {:ok, account_view, _html} = Phoenix.LiveViewTest.live(account_form_conn)

    account_view
    |> Phoenix.LiveViewTest.form("#account_form", account: %{name: "Personal"})
    |> Phoenix.LiveViewTest.render_submit()

    # Re-mount /app/onboarding now that the active account is set —
    # the LV is in the project-name step that downstream specs assert on.
    onboarding_conn =
      Phoenix.ConnTest.dispatch(
        Phoenix.ConnTest.recycle(account_form_conn),
        CodeMySpecWeb.Endpoint,
        :get,
        "/app/onboarding"
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
