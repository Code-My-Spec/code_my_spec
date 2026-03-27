defmodule CodeMySpec.Integration.WorkflowHelpers do
  @moduledoc """
  Setup helpers for integration workflow tests.

  Builds a minimal requirements graph and session for testing
  MCP tool chains without filesystem dependencies.
  """

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Environments.Environment
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
    scope = %{scope | environment: Environment.new(:local, tmp_dir)}
    external_id = "workflow-#{System.unique_integer([:positive])}"
    {:ok, session} = Sessions.find_or_create_session(scope, external_id)
    frame = %Frame{assigns: %{current_scope: scope}}
    project = scope.active_project

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
  Extracts the text content from an MCP tool response.
  """
  def response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end

  @doc """
  Extracts the structured data from an MCP response.
  """
  def extract_data(%{structured_content: data}) when is_map(data) do
    # Normalize atom keys to strings for consistent assertions
    Jason.decode!(Jason.encode!(data))
  end

  def extract_data(_), do: %{}
end
