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
  alias CodeMySpec.McpServers.Requirements.RequirementsMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        case Requirements.next_actionable_project(scope) do
          [] ->
            {:reply, RequirementsMapper.all_satisfied_response(), frame}

          [req | _] ->
            req = Repo.preload(req, [:component, :story, :project])
            {:reply, RequirementsMapper.next_requirement_response(req), frame}
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
