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
  - `technical_strategy` (blocked, depends on project_setup) — uses ProjectSetup for simplicity

  Scope includes an environment backed by a tmp directory for filesystem control.

  Returns `%{scope, frame, session_id, project, req1, req2, tmp_dir}`.
  """
  def setup_workflow_scenario do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()

    # Set local_path so the WorkingDirScope plug can find this project
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})
    scope = %{scope | active_project: project, environment: Environment.new(:local, tmp_dir)}

    external_id = "workflow-#{System.unique_integer([:positive])}"
    {:ok, session} = Sessions.find_or_create_session(scope, external_id)
    frame = %Frame{assigns: %{current_scope: scope}}

    req1 =
      project_requirement_fixture(scope, %{
        name: "project_setup",
        artifact_type: :specification,
        satisfied: false,
        satisfied_by: CodeMySpec.AgentTasks.ProjectSetup
      })

    req2 =
      project_requirement_fixture(scope, %{
        name: "technical_strategy",
        artifact_type: :specification,
        satisfied: false,
        satisfied_by: CodeMySpec.AgentTasks.ProjectSetup,
        depends_on: [
          %{
            "entity_type" => "project",
            "entity_id" => project.id,
            "requirement_name" => "project_setup"
          }
        ]
      })

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

  defp project_requirement_fixture(scope, attrs) do
    attrs =
      Map.merge(
        %{
          description: "test",
          checker_module: CodeMySpec.Requirements.ArtifactExistenceChecker,
          score: 0.0,
          checked_at: DateTime.utc_now()
        },
        attrs
      )

    {:ok, req} =
      CodeMySpec.Requirements.RequirementsRepository.create_project_requirement(
        scope,
        scope.active_project,
        attrs
      )

    req
  end

  @doc """
  Seeds the tmp directory with files that satisfy all 12 setup steps.

  Writes the minimal files each step's evaluate checks for:
  mix.exs with deps/compilers/spex config, .code_my_spec/ directory structure,
  test support files, .credo.exs, CLAUDE.md, etc.
  """
  def seed_all_setup_steps(tmp_dir) do
    app = "my_app"

    # mix.exs — satisfies CodemyspecDeps, Compilers, SpexConfig
    File.write!(Path.join(tmp_dir, "mix.exs"), """
    defmodule MyApp.MixProject do
      use Mix.Project
      def project do
        [app: :my_app, compilers: compilers(Mix.env())]
      end
      defp compilers(:test), do: [:boundary, :spex]
      defp compilers(_), do: [:boundary]
      def cli, do: [preferred_envs: [spex: :test]]
      defp deps do
        [{:credo, "~> 1.0"}, {:client_utils, "~> 0.1"}, {:sobelow, "~> 0.1"}, {:sexy_spex, "~> 0.1"}, {:boundary, "~> 0.1"}]
      end
    end
    """)

    # ApplicationInWeb
    web_app_dir = Path.join([tmp_dir, "lib", "#{app}_web"])
    File.mkdir_p!(web_app_dir)
    File.write!(Path.join(web_app_dir, "application.ex"), "defmodule MyAppWeb.Application do\nend")

    # TestBoundaries
    test_support = Path.join([tmp_dir, "test", "support"])
    File.mkdir_p!(test_support)
    File.write!(Path.join(test_support, "#{app}_spex.ex"), "defmodule MyAppSpex do\n  use Boundary\nend")
    File.write!(Path.join(test_support, "#{app}_test_boundary.ex"), "defmodule MyAppTest do\n  use Boundary\nend")

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
    File.write!(Path.join(tmp_dir, "CLAUDE.md"), "# Project\n<!-- code_my_spec:start -->\nmanaged\n<!-- code_my_spec:end -->")

    :ok
  end

  @doc """
  Extracts the text content from an MCP tool response.
  """
  def response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end

end
