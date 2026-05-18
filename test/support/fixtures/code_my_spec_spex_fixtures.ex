defmodule CodeMySpecSpex.Fixtures do
  @moduledoc """
  Approved bridge from spex tests into app-level DB setup.

  Specs can only reach into the app through this module. The boundary
  enforces it: `CodeMySpecSpex` depends on `CodeMySpecSpex.Fixtures`,
  not on `CodeMySpec` or `CodeMySpecTest` directly.

  Only surfaces fixtures for state that **originates server-side and
  syncs into the local app** — users, accounts, projects. Components
  and stories are surface-creatable through MCP tools, so spex tests
  drive them directly via `CodeMySpecSpex.ComponentHelpers` and
  `CodeMySpecSpex.StoryHelpers`. Local-only state
  (ProjectConfiguration, etc.) must be set up through the UI like
  any other user action.
  """
  use Boundary, top_level?: true, deps: [CodeMySpec, CodeMySpec.Environments, CodeMySpecTest]

  alias CodeMySpec.{
    AccountsFixtures,
    AgentTasks,
    ArchitectureFixtures,
    BddSpecs,
    CodeGenerationFixtures,
    Components,
    EmbeddingsFixtures,
    EnvironmentFixtures,
    Environments,
    IssuesFixtures,
    OauthFixtures,
    Paths,
    ProblemsFixtures,
    ProjectsFixtures,
    ProjectSync,
    QaFixtures,
    QaIntegrationPlanFixtures,
    Sessions,
    SetupFixtures,
    Stories,
    TechnicalStrategyFixtures,
    UserPreferences,
    Users,
    UsersFixtures
  }

  alias CodeMySpec.Users.Scope

  def generate_user_session_token(user), do: Users.generate_user_session_token(user)
  def select_active_account(scope, account_id), do: UserPreferences.select_active_account(scope, account_id)
  def select_active_project(scope, project_id), do: UserPreferences.select_active_project(scope, project_id)

  # -- Environments --
  defdelegate memory_environment_fixture(opts \\ []), to: EnvironmentFixtures
  defdelegate register_environment(project_id, env), to: Environments, as: :register
  defdelegate unregister_environment(project_id), to: Environments, as: :unregister

  # -- Paths (conventional project resource paths) --
  defdelegate base_dir(), to: Paths
  defdelegate proposal_path(), to: Paths
  defdelegate spec_file(module_path), to: Paths

  # -- Project Sync (file-change events) --
  @doc """
  Synthesizes the "a file changed" event the file watcher fires in
  production. Takes a relative path inside the scope's project tree;
  resolves to absolute via `scope.cwd`. Runs the same orchestration
  the OS watcher would: classify + upsert/delete the File row, refresh
  fingerprint, fan out to ComponentSync, broadcast on the watcher
  PubSub topic.
  """
  @spec notify_file_changed(Scope.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def notify_file_changed(%Scope{} = scope, rel_path) when is_binary(rel_path) do
    ProjectSync.Sync.sync_path(scope, Path.join(scope.cwd, rel_path))
  end

  # -- Project Setup (Story 124) --
  defdelegate satisfy_setup_steps(env, steps), to: SetupFixtures, as: :satisfy
  defdelegate reset_setup_env(env), to: SetupFixtures, as: :reset
  defdelegate setup_steps(), to: AgentTasks.ProjectSetup
  defdelegate step_name(mod), to: AgentTasks.ProjectSetup
  defdelegate find_setup_step(id), to: AgentTasks.ProjectSetup, as: :find_step

  @doc "Returns the stub setup-step module that always errors. Used by Story 124's error-path spex."
  def erroring_setup_step, do: CodeMySpec.SetupFixtures.ErroringStep

  # -- Technical Strategy (Story 80) --
  defdelegate with_mix_exs(env), to: TechnicalStrategyFixtures
  defdelegate with_custom_adr(env, topic, marker), to: TechnicalStrategyFixtures
  defdelegate with_decisions_index(env), to: TechnicalStrategyFixtures
  defdelegate read_adr(env, topic), to: TechnicalStrategyFixtures
  defdelegate adr_exists?(env, topic), to: TechnicalStrategyFixtures

  # -- Code Generation --
  defdelegate with_baseline_project(env), to: CodeGenerationFixtures
  defdelegate with_decision(env, topic), to: CodeGenerationFixtures
  defdelegate with_decisions(env, topics), to: CodeGenerationFixtures
  defdelegate with_integration_spec(env, provider), to: CodeGenerationFixtures
  defdelegate with_integration_specs(env, providers), to: CodeGenerationFixtures
  defdelegate with_generator_applied(env, generator_id), to: CodeGenerationFixtures
  defdelegate with_all_generators_applied(env), to: CodeGenerationFixtures
  defdelegate generator_applied?(env, generator_id), to: CodeGenerationFixtures
  defdelegate generator_ids(), to: CodeGenerationFixtures
  defdelegate with_full_script(env), to: CodeGenerationFixtures
  defdelegate with_empty_script(env), to: CodeGenerationFixtures
  defdelegate with_existing_script(env, body), to: CodeGenerationFixtures
  defdelegate read_script(env), to: CodeGenerationFixtures
  defdelegate script_exists?(env), to: CodeGenerationFixtures

  # -- QA Integration Plan --
  defdelegate with_decision_for_service(env, service, opts \\ []),
    to: QaIntegrationPlanFixtures

  defdelegate with_verified_integration_spec(env, name), to: QaIntegrationPlanFixtures
  defdelegate with_pending_integration_spec(env, name), to: QaIntegrationPlanFixtures

  defdelegate with_integration_spec_missing_verify_script(env, name),
    to: QaIntegrationPlanFixtures

  defdelegate with_verify_script(env, name), to: QaIntegrationPlanFixtures
  defdelegate with_integration_index(env, topics), to: QaIntegrationPlanFixtures
  defdelegate with_empty_integration_index(env), to: QaIntegrationPlanFixtures
  defdelegate with_verified_integration(env, name), to: QaIntegrationPlanFixtures
  defdelegate read_integration_spec(env, name), to: QaIntegrationPlanFixtures
  defdelegate integration_spec_exists?(env, name), to: QaIntegrationPlanFixtures
  defdelegate integration_index_exists?(env), to: QaIntegrationPlanFixtures
  defdelegate verify_script_exists?(env, name), to: QaIntegrationPlanFixtures

  # -- Embeddings --
  defdelegate write_framework_knowledge_file(dir, filename, content), to: EmbeddingsFixtures
  defdelegate simulate_framework_knowledge_boot_embed(scope), to: EmbeddingsFixtures

  # -- Continuous mode (Story 538) --
  @doc """
  Drive the real `POST /api/skills/start` endpoint with skill=implement
  so the agent's autonomous loop is enabled on the named session.

  Production surface: `cms implement` (CLI) → POST /api/skills/start
  → SkillController.start_skill → StartAgentTask.run("start_implementation")
  → StartImplementation.init_session sets `session.continuous = true`.

  Returns `:ok`. The session's `external_id` is whatever the caller passed
  in; calling this AFTER a regular `start_task` for that session flips the
  continuous flag on the existing row.
  """
  @spec start_continuous_mode(map(), String.t()) :: :ok
  def start_continuous_mode(scope, external_id) when is_binary(external_id) do
    response =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("x-working-dir", scope.cwd)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Phoenix.ConnTest.dispatch(
        CodeMySpecLocalWeb.Endpoint,
        :post,
        "/api/skills/start",
        %{"skill" => "implement", "external_id" => external_id}
      )
      |> Phoenix.ConnTest.json_response(200)

    case response do
      %{"prompt" => _} -> :ok
      _ -> raise "start_continuous_mode failed: #{inspect(response)}"
    end
  end

  # -- Tap-out human response (Story 704 / Rule 5) --
  @doc """
  Simulate the human responding to a pending tap-out request.

  Spex use this to drive the approval/rejection side without a real
  production-server round-trip. Wraps `CodeMySpec.Permissions.TapOut.respond/4`.
  """
  @spec respond_to_tap_out(map(), String.t(), String.t(), :approve | :reject) ::
          {:ok, CodeMySpec.Sessions.Session.t()} | {:error, term()}
  def respond_to_tap_out(scope, session_external_id, request_id, decision)
      when decision in [:approve, :reject] do
    session = CodeMySpec.Sessions.get_by_external_id(scope, session_external_id)
    CodeMySpec.Permissions.TapOut.respond(scope, session, request_id, decision)
  end

  @doc """
  Returns the PubSub topic that tap-out events are broadcast on.

  Spex subscribe to this topic to assert that `tap_out` MCP calls
  publish the expected messages without referencing the internal
  `CodeMySpec.Permissions.TapOut` module directly.
  """
  @spec tap_out_pubsub_topic() :: String.t()
  def tap_out_pubsub_topic, do: "permissions:tap_out"

  @doc """
  Looks up a session by its external conversation id (the string the
  agent passes as `session_id` in hook calls). Returns the DB row so
  spex can extract the UUID needed for LiveView route params.
  """
  @spec get_session_by_external_id(Scope.t(), String.t()) :: CodeMySpec.Sessions.Session.t() | nil
  def get_session_by_external_id(%Scope{} = scope, session_external_id)
      when is_binary(session_external_id) do
    Sessions.get_by_external_id(scope, session_external_id)
  end

  # -- Sub-agent registration with custom heartbeat (Story 704) --
  @doc """
  Register a sub-agent on a session with a specific `last_heartbeat_at`.

  Used by spex that need to seed a TTL-expired registration (heartbeat
  in the past) without manipulating the system clock. Goes through the
  same `Sessions.register_subagent/3` context function the production
  hook uses; only the timestamp differs.

  Returns `{:ok, session}` with the registration applied.
  """
  @spec register_subagent_with_heartbeat(map(), String.t(), map()) ::
          {:ok, CodeMySpec.Sessions.Session.t()} | {:error, Ecto.Changeset.t()}
  def register_subagent_with_heartbeat(scope, session_external_id, attrs)
      when is_binary(session_external_id) and is_map(attrs) do
    session = CodeMySpec.Sessions.get_by_external_id(scope, session_external_id)
    CodeMySpec.Sessions.register_subagent(scope, session, attrs)
  end

  # -- Users --
  defdelegate user_fixture(attrs \\ %{}), to: UsersFixtures
  defdelegate user_scope_fixture(), to: UsersFixtures
  defdelegate user_scope_fixture(user), to: UsersFixtures
  defdelegate user_scope_fixture(user, account), to: UsersFixtures
  defdelegate user_scope_fixture(user, account, project), to: UsersFixtures
  defdelegate full_scope_fixture(), to: UsersFixtures
  defdelegate full_scope_fixture(project_attrs), to: UsersFixtures
  defdelegate expire_magic_link_tokens_for(email), to: UsersFixtures

  # -- Accounts --
  defdelegate account_fixture(attrs \\ %{}), to: AccountsFixtures
  defdelegate account_with_owner_fixture(user, attrs \\ %{}), to: AccountsFixtures
  defdelegate member_fixture(user, account, role \\ :member), to: AccountsFixtures

  # -- Projects --
  defdelegate project_fixture(scope, attrs \\ %{}), to: ProjectsFixtures

  @doc """
  Creates a project whose `local_path` points at a freshly-created tmp
  directory that is NOT the spex's `scope.cwd`. Used by scenarios that
  want a project to exist in the DB while leaving the spex's working
  directory *unlinked* (e.g. Story 711 / criterion 6255 — the agent is
  in a working dir with no project row pointing at it, so `CliConfig`
  must surface the `list_projects` + `init_project` directive).

  Returns the project struct. The unlinked tmp dir is removed on
  test exit.
  """
  @spec project_fixture_unlinked(Scope.t(), map() | keyword()) ::
          CodeMySpec.Projects.Project.t()
  def project_fixture_unlinked(%Scope{} = scope, attrs \\ %{}) do
    unlinked_dir =
      Path.join(System.tmp_dir!(), "spex-unlinked-#{System.unique_integer([:positive])}")

    File.mkdir_p!(unlinked_dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(unlinked_dir) end)

    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put_new(:local_path, unlinked_dir)

    ProjectsFixtures.project_fixture(scope, attrs)
  end

  # -- Stories (QA spex fixture setup, Stories 726/727) --
  @doc """
  Creates a story directly through the Stories context for use in QA
  spex setup. Returns the created story struct.
  """
  @spec story_fixture(Scope.t(), map()) :: CodeMySpec.Stories.Story.t()
  def story_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        title: "QA Story #{System.unique_integer([:positive])}",
        description: "A story for QA spex testing",
        status: :in_progress
      })

    {:ok, story} = Stories.create_story(scope, attrs)
    story
  end

  # -- Sessions (QA spex fixture setup, Stories 726/727) --
  @doc """
  Creates an active session with a `qa_complete` task linked to the given
  story. Used by QA spex setup to seed `context.story` and `context.task_id`
  without needing the full requirement prerequisite chain satisfied.

  Returns `{story, task_id, session}`.
  """
  @spec qa_story_task_fixture(Scope.t(), keyword()) ::
          {CodeMySpec.Stories.Story.t(), String.t(), CodeMySpec.Sessions.Session.t()}
  def qa_story_task_fixture(scope, opts \\ []) do
    story =
      case Keyword.fetch(opts, :story) do
        {:ok, existing} ->
          existing

        :error ->
          story_fixture(scope, %{
            title: Keyword.get(opts, :title, "QA Story #{System.unique_integer([:positive])}"),
            description: Keyword.get(opts, :description, "Story for QA testing"),
            status: :in_progress
          })
      end

    task_id = Ecto.UUID.generate()
    session_external_id = "spex-qa-#{System.unique_integer([:positive])}"

    {:ok, session} =
      Sessions.create_session(scope, %{
        external_conversation_id: session_external_id,
        status: :active,
        type: CodeMySpec.AgentTasks.QaStory,
        tasks: [
          %{
            id: task_id,
            status: :active,
            requirement_name: "qa_complete",
            story_id: story.id,
            project_id: scope.active_project_id,
            agent_id: "spex-agent",
            started_at: DateTime.utc_now()
          }
        ]
      })

    {story, task_id, session}
  end

  # -- Components --
  defdelegate get_component_by_module_name(scope, module_name), to: Components

  # -- Architecture --
  defdelegate proposal_with_context(app, name, description), to: ArchitectureFixtures
  defdelegate proposal_with_surface_and_context(opts \\ []), to: ArchitectureFixtures
  defdelegate with_proposal(env, content), to: ArchitectureFixtures
  defdelegate with_executed_proposal(scope, env, content), to: ArchitectureFixtures
  defdelegate dependency_fixture(scope, source, target), to: ArchitectureFixtures
  defdelegate component_fixture(scope, attrs), to: ArchitectureFixtures

  # -- BDD Specs --
  defdelegate spec_file_path(story, criterion), to: BddSpecs

  # -- Problems --
  defdelegate problem_fixture(scope, attrs \\ %{}), to: ProblemsFixtures

  # -- Issues (QA triage / fix scenarios) --
  defdelegate issue_fixture(scope, attrs \\ %{}), to: IssuesFixtures

  # -- QA Attempts --
  defdelegate passed_qa_attempt(scope, opts \\ []), to: QaFixtures

  # -- OAuth (CLI client for Story 698) --
  defdelegate cli_oauth_application_fixture(attrs \\ %{}), to: OauthFixtures

  # -- Analytics (Story 698) --
  defdelegate attach_analytics_test_subscriber(pid),
    to: CodeMySpec.Analytics,
    as: :attach_test_subscriber

  defdelegate detach_analytics_test_subscriber(pid),
    to: CodeMySpec.Analytics,
    as: :detach_test_subscriber

  defdelegate attach_ga_test_subscriber(pid),
    to: CodeMySpec.Analytics.GoogleAnalytics,
    as: :attach_test_subscriber

  defdelegate detach_ga_test_subscriber(pid),
    to: CodeMySpec.Analytics.GoogleAnalytics,
    as: :detach_test_subscriber

  # -- Local app onboarding (Story 701) --

  @doc """
  Seeds a `client_users` row with a non-expired OAuth token for the
  test user. The local app's auth rung evaluates "done" against the
  presence of this row (same predicate `OAuthClient.authenticated?/0`
  returns).
  """
  def client_user_fixture(user, opts \\ []) do
    expires_in = Keyword.get(opts, :expires_in, 3600)
    suffix = System.unique_integer([:positive])

    token_data = %{
      "access_token" => "test-access-#{suffix}",
      "refresh_token" => "test-refresh-#{suffix}",
      "expires_in" => expires_in
    }

    {:ok, client_user} =
      CodeMySpec.Auth.OAuthClient.save_client_user(user.id, user.email, token_data)

    client_user
  end

  @doc """
  Records a `local_init_complete` event for the active project so the
  per-project ladder's init rung evaluates as "done." For tests where
  the scenario's intent is "init has been run."
  """
  def satisfy_init(%{active_project: project}) when not is_nil(project) do
    {:ok, _event} =
      CodeMySpec.Events.record("local_init_complete", %{project_id: project.id})

    :ok
  end

  @doc """
  Records a `local_project_setup_complete` event for the active project
  so the per-project ladder's setup rung evaluates as "done."
  """
  def satisfy_project_setup(%{active_project: project}) when not is_nil(project) do
    {:ok, _event} =
      CodeMySpec.Events.record("local_project_setup_complete", %{project_id: project.id})

    :ok
  end

  # -- Framework-issue remote stub --

  @doc """
  Resets the in-process framework-issue stub. Spex setup should call
  this so each scenario starts with an empty server-side capture.
  """
  def reset_framework_issue_stub do
    CodeMySpec.Issues.RemoteClientStub.reset()
  end

  @doc """
  Returns the framework issues captured by the remote stub during this
  test. Lets a `then_` step assert "the framework write reached the
  server surface" through the approved bridge instead of touching the
  stub module directly.
  """
  def captured_framework_issues do
    CodeMySpec.Issues.RemoteClientStub.stored_issues()
  end

  @doc """
  Seeds a server-side incoming issue on the stub. Spex use this to
  prime the "server" before calling `start_task` for `issues_triaged`
  (which triggers the triage-start pull) or `accept_issue` /
  `dismiss_issue` / `resolve_issue` on a server-origin record.
  """
  def seed_server_incoming_issue(scope, attrs) do
    CodeMySpec.Issues.RemoteClientStub.seed_incoming_issue(scope, attrs)
  end

  @doc """
  Toggles the simulated server-unreachable flag on the stub. Set
  `true` before a `when_` step to exercise the fail-loud paths in 599
  (triage start) and 709 (disposition sync-back).
  """
  def simulate_server_unreachable(flag) when is_boolean(flag) do
    CodeMySpec.Issues.RemoteClientStub.simulate_unreachable(flag)
  end

  @doc """
  Drives `Issues.pull_incoming_from_remote/1` through the bridge so
  spex can stage the "after triage-start pull" state without calling
  `start_task` end-to-end (used by 709's disposition spex to focus on
  the sync-back rule, not the pull rule).
  """
  def sync_server_issues_to_local(scope) do
    CodeMySpec.Issues.RemoteClientStub.pull_to_local(scope)
  end

  @doc """
  Returns the recorded `update_issue` calls the stub captured for a
  given issue id. Lets `then_` steps assert "the local disposition
  round-tripped to the server" through the approved bridge.
  """
  def server_update_calls_for(issue_id) when is_binary(issue_id) do
    CodeMySpec.Issues.RemoteClientStub.update_calls_for(issue_id)
  end
end
