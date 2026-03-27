defmodule CodeMySpec.Integration.WorkflowHelpers do
  @moduledoc """
  Setup helpers for integration workflow tests.

  Builds a minimal requirements graph and session for testing
  MCP tool chains without filesystem dependencies.
  """

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.RequirementsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Sessions

  @doc """
  Creates a scope, session, frame, and a two-requirement graph:

  - `spec_file` (actionable, no deps)
  - `tests_passing` (blocked, depends on spec_file)

  Both use RefactorModule (evaluate always returns :valid).

  Returns `%{scope, frame, session_id, component, req1, req2}`.
  """
  def setup_workflow_scenario do
    scope = full_scope_fixture()
    component = component_fixture(scope)
    external_id = "workflow-#{System.unique_integer([:positive])}"
    {:ok, session} = Sessions.find_or_create_session(scope, external_id)
    frame = %Frame{assigns: %{current_scope: scope}}

    req1 =
      requirement_fixture(scope, component, %{
        name: "spec_file",
        artifact_type: :specification,
        satisfied: false,
        satisfied_by: CodeMySpec.AgentTasks.RefactorModule
      })

    req2 =
      requirement_fixture(scope, component, %{
        name: "tests_passing",
        artifact_type: :tests,
        satisfied: false,
        satisfied_by: CodeMySpec.AgentTasks.RefactorModule,
        depends_on: [
          %{
            "entity_type" => "component",
            "entity_id" => component.id,
            "requirement_name" => "spec_file"
          }
        ]
      })

    %{
      scope: scope,
      frame: frame,
      session_id: session.id,
      component: component,
      req1: req1,
      req2: req2
    }
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
