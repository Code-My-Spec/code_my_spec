defmodule CodeMySpecLocalWeb.Hooks.SubagentStopController do
  @moduledoc """
  Handles the SubagentStop hook event.

  Validates the subagent's transcript.
  """
  use CodeMySpecLocalWeb, :controller

  require Logger

  alias CodeMySpec.Validation

  def handle(conn, params) do
    scope = conn.assigns.current_scope
    agent_transcript_path = Map.get(params, "agent_transcript_path")

    result = Validation.validate_subagent(scope, transcript_path: agent_transcript_path)
    json(conn, Validation.format_output(result))
  end
end
