defmodule CodeMySpec.McpServers.Requirements.Tools.ListRequirements do
  @moduledoc """
  List all project requirements with their satisfaction status.

  Returns every requirement across all entities (project, stories, components),
  grouped by entity, showing which are satisfied and which still need work.

  This is a read-only discovery tool — use it to understand the full picture
  of what needs doing before picking a requirement to work on.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Requirements

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      %{nodes: nodes} = Requirements.project_graph(scope)

      {:reply, RequirementsMapper.list_requirements_response(nodes), frame}
    else
      {:error, reason} ->
        {:reply, RequirementsMapper.error(reason), frame}
    end
  end
end
