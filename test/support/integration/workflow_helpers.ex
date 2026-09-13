defmodule CodeMySpec.Integration.WorkflowHelpers do
  @moduledoc """
  Setup helpers for integration workflow tests.

  Builds a minimal requirements graph and session for testing
  MCP tool chains without filesystem dependencies.
  """

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Projects
  alias CodeMySpec.Sessions

  @doc """
  Creates a scope, session, frame, and a two-requirement graph:

  - `project_setup` (actionable, no deps) — uses ProjectSetup task module
  - `qa_setup` (blocked) — a second project-level requirement

  Scope includes an environment backed by a tmp directory for filesystem control.

  Returns `%{scope, frame, session_id, project, req1, req2, tmp_dir}`.
  """
  def setup_workflow_scenario do
    tmp_dir = temp_dir("workflow_scenario")
    scope = full_scope_fixture()

    # Set local_path so the WorkingDirScope plug can find this project
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

    scope = %{
      scope
      | active_project: project,
        environment: Environment.new(:local, tmp_dir),
        cwd: tmp_dir
    }

    external_id = "workflow-#{System.unique_integer([:positive])}"
    {:ok, session} = Sessions.find_or_create_session(scope, external_id)
    frame = %Frame{assigns: %{current_scope: scope}}

    # `req1` is the chain's vehicle: something automatic, so the stop hook can
    # actually evaluate it. It used to be `project_setup`, which left the graph
    # when `cms new` took setup over — and the graph's new root,
    # `personas_complete`, is `validation_type: :manual`, so the stop hook skips
    # it and there is nothing to assert.
    #
    # `technical_strategy` is `path_exists` on a file under `.code_my_spec/`, so
    # a test satisfies it by writing one into the tmp dir. Blocked in the graph,
    # which does not matter here: `start_task` takes a named requirement rather
    # than an actionable one.
    req1 = project_requirement_ref(scope, "technical_strategy")
    req2 = project_requirement_ref(scope, "qa_setup")

    %{
      scope: scope,
      frame: frame,
      session_id: session.id,
      external_session_id: external_id,
      project: project,
      req1: req1,
      req2: req2,
      tmp_dir: tmp_dir
    }
  end

  @doc """
  Returns a map matching the shape expected by StartTask for a project-level requirement.

  Since requirements are now computed (not persisted), this just returns
  the params needed to start a task via the graph.
  """
  def project_requirement_ref(scope, name) do
    %{
      requirement_name: name,
      entity_type: "project",
      entity_id: to_string(scope.active_project_id)
    }
  end

  @doc """
  Seeds the tmp directory with files that satisfy all 12 setup steps.

  Writes the minimal files each step's evaluate checks for:
  mix.exs with deps/compilers/spex config, .code_my_spec/ directory structure,
  test support files, .credo.exs, CLAUDE.md, etc.
  """
  def seed_all_setup_steps(tmp_dir) do
    app = "my_app"

    # mix.exs — fixture for the setup-step validators (CodemyspecDeps,
    # Compilers, SpexConfig). The validators are text/regex-based —
    # they look for `:boundary`/`:spex` near "compilers" and the dep
    # atoms in the file content. We deliberately keep the *real*
    # `compilers:` value out of `def project` so that running
    # `mix compile` against this fixture (StaticAnalysis pipeline does
    # this in cwd) doesn't try to load `:boundary` / `:spex` compilers
    # — the fixture has no deps installed, so those tasks aren't
    # available. Defaults give a no-op compile, which is what we want.
    File.write!(Path.join(tmp_dir, "mix.exs"), """
    defmodule MyApp.MixProject do
      use Mix.Project

      # Production mix.exs sets:
      #   compilers: [:diagnostics, :boundary, :phoenix_live_view, :erlang, :elixir, :spex, :app]
      # The setup validators look for :boundary and :spex in the source
      # text near "compilers"; they don't load the file as code.

      def project, do: [app: :my_app, version: "0.0.0"]

      def cli, do: [preferred_envs: [spex: :test]]

      # Required deps per setup: :credo, :client_utils, :sobelow, :sexy_spex, :boundary, :code_my_spec_generators.
      # Listed for the validator; not actually fetched in this fixture.
      def deps do
        [
          {:credo, "~> 1.0"},
          {:client_utils, "~> 0.1"},
          {:sobelow, "~> 0.1"},
          {:sexy_spex, "~> 0.1"},
          {:boundary, "~> 0.1"},
          {:code_my_spec_generators, "~> 0.1", only: :dev}
        ]
      end
    end
    """)

    # ApplicationInWeb
    web_app_dir = Path.join([tmp_dir, "lib", "#{app}_web"])
    File.mkdir_p!(web_app_dir)

    File.write!(
      Path.join(web_app_dir, "application.ex"),
      "defmodule MyAppWeb.Application do\nend"
    )

    # TestBoundaries
    test_support = Path.join([tmp_dir, "test", "support"])
    File.mkdir_p!(test_support)

    File.write!(
      Path.join(test_support, "#{app}_spex.ex"),
      "defmodule MyAppSpex do\n  use Boundary\nend"
    )

    File.write!(
      Path.join(test_support, "#{app}_test_boundary.ex"),
      "defmodule MyAppTest do\n  use Boundary\nend"
    )

    # SpexCase — validator requires defmodule <App>Spex.Case + use SexySpex + import Phoenix.LiveViewTest
    File.write!(
      Path.join(test_support, "#{app}_spex_case.ex"),
      """
      defmodule MyAppSpex.Case do
        use ExUnit.CaseTemplate
        use SexySpex
        import Phoenix.LiveViewTest
      end
      """
    )

    # TestSupportNamespace
    File.write!(Path.join(test_support, "conn_case.ex"), "defmodule MyAppTest.ConnCase do\nend")
    File.write!(Path.join(test_support, "data_case.ex"), "defmodule MyAppTest.DataCase do\nend")

    # ProjectStructure
    base = ".code_my_spec"

    for dir <- [
          Path.join(base, "rules"),
          Path.join([base, "spec", app]),
          Path.join([base, "spec", "#{app}_web"])
        ] do
      File.mkdir_p!(Path.join(tmp_dir, dir))
    end

    # AppResources — framework, tools, credo_checks dirs
    for dir <- [
          Path.join(base, "framework"),
          Path.join(base, "tools"),
          Path.join([base, "credo_checks"])
        ] do
      File.mkdir_p!(Path.join(tmp_dir, dir))
    end

    # AgentsMd
    File.write!(Path.join([tmp_dir, base, "AGENTS.md"]), "# Agents Guide")

    # Rules — at least one .md file
    File.write!(Path.join([tmp_dir, base, "rules", "context.md"]), "# Context Rules")

    # CredoChecks
    File.write!(Path.join(tmp_dir, ".credo.exs"), """
    %{configs: [%{
      requires: [".code_my_spec/credo_checks/framework/**/*.ex", ".code_my_spec/credo_checks/local/**/*.ex"],
      checks: %{extra: if(File.exists?(".code_my_spec/credo_checks/framework/checks.exs"), do: [], else: [])}
    }]}
    """)

    # ClaudeMd
    File.write!(
      Path.join(tmp_dir, "CLAUDE.md"),
      "# Project\n<!-- code_my_spec:start -->\nmanaged\n<!-- code_my_spec:end -->"
    )

    # infrastructure_paths — framework-generated modules that ComponentSync
    # tags as `type: "infrastructure"` (empty requirement graph, no work driven).
    # The list mirrors the standard Phoenix scaffold; projects can edit it.
    File.write!(Path.join([tmp_dir, base, "config.yml"]), """
    infrastructure_paths:
      - lib/#{app}/application.ex
      - lib/#{app}/repo.ex
      - lib/#{app}/mailer.ex
      - lib/#{app}/release.ex
      - lib/#{app}.ex
      - lib/#{app}_web.ex
      - lib/#{app}_web/application.ex
      - lib/#{app}_web/endpoint.ex
      - lib/#{app}_web/router.ex
      - lib/#{app}_web/telemetry.ex
      - lib/#{app}_web/gettext.ex
      - lib/#{app}_web/components/core_components.ex
      - lib/#{app}_web/components/layouts.ex
      - lib/#{app}_web/controllers/error_*
      - lib/#{app}_web/controllers/page_*
    """)

    # ProjectStructure — required spec dirs
    File.mkdir_p!(Path.join([tmp_dir, base, "spec", app]))
    File.mkdir_p!(Path.join([tmp_dir, base, "spec", "#{app}_web"]))

    :ok
  end

  @doc """
  Extracts the text content from an MCP tool response.
  """
  def response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end

  # A temp directory, without `Briefly`.
  #
  # `Briefly.Entry.ensure_tmp/0` asks one GenServer for the calling process's
  # temp root with a hardcoded 5-second `GenServer.call` and no option to raise
  # it, so on a box running several suites at once it times out and the test
  # exits — `** (exit) exited in: GenServer.call(_, {:monitor, _}, 5000)`,
  # recorded as a failure and blocking every promotion until somebody re-ran the
  # suite while the machine was quiet. `TempFile.dir/1` touches no process.
  #
  # Cleanup is ours now rather than Briefly's process-exit hook. Registered at
  # the point the directory is made, and `on_exit` is LIFO, so it runs after
  # anything the caller registers afterwards.
  defp temp_dir(prefix) do
    dir = CodeMySpec.TempFile.dir(prefix)
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
