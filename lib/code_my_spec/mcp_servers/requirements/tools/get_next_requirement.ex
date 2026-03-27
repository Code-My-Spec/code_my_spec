defmodule CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement do
  @moduledoc """
  Get the next actionable requirement for the project.

  Returns the single highest-priority requirement that is unsatisfied, has all
  prerequisites met, and has a task module that can satisfy it.

  This is a read-only discovery tool — use it as a shortcut when you just want
  the next thing to work on. Call `start_task` with the returned requirement_id
  to begin work.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      case Requirements.next_actionable_project(scope) do
        [] ->
          {:reply, RequirementsMapper.all_satisfied_response(), frame}

        [req | _] ->
          req = Repo.preload(req, [:component, :story, :project])
          {:reply, RequirementsMapper.next_requirement_response(req), frame}
      end
    else
      {:error, reason} ->
        {:reply, RequirementsMapper.error(reason), frame}
    end
  end
end
