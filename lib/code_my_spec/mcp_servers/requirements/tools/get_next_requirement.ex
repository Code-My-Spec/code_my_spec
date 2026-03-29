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

  alias CodeMySpec.AgentTasks.Init
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Files.ComponentSync, as: FileComponentSync
  alias CodeMySpec.Files.RequirementGraph
  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        # Sync files + components before computing the graph
        if scope.cwd do
          FileSync.sync(scope, base_dir: scope.cwd)
          FileComponentSync.sync_from_files(scope, base_dir: scope.cwd)
        end

        case RequirementGraph.next_actionable(scope) do
          [] ->
            all = RequirementGraph.compute_all(scope)

            if all == [] do
              {:reply, RequirementsMapper.sync_required_response(), frame}
            else
              {:reply, RequirementsMapper.all_satisfied_response(), frame}
            end

          [node | _] ->
            {:reply, RequirementsMapper.next_requirement_response(node), frame}
        end

      {:error, _reason} ->
        # No project linked — return init checklist so the agent can bootstrap
        scope = build_init_scope(frame)
        {:ok, prompt} = Init.command(scope, %{})
        {:reply, RequirementsMapper.init_required_response(prompt), frame}
    end
  end

  defp build_init_scope(frame) do
    working_dir = frame.assigns[:working_dir] || Validators.mcp_working_dir(frame)
    %{cwd: working_dir}
  end
end
