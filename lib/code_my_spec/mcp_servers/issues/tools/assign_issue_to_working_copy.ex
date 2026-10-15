defmodule CodeMySpec.McpServers.Issues.Tools.AssignIssueToWorkingCopy do
  @moduledoc """
  Assigns an issue to a working copy's coding and QA team.

  Adds an accepted issue to the team's bag without replacing its current
  priority. Assignment clears the team's story assignment and story queue,
  even when the issue itself belongs to a story. The first issue establishes
  the active priority. Use `set_active_issue`
  to prioritize another member and `unassign_issue` to remove one.
  Moving an issue preserves its workflow stage and transfers its open tasks.
  Coding and QA may work on different eligible issues from the same bag.

  Main or the operator can pass `rework: true` and a correction `reason`
  for an accepted issue awaiting QA on the same copy. With no open issue
  task, this returns the issue to coding and records the instructions;
  completed fix tasks remain completed. Ordinary reassignment preserves
  the current turn.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :issue_id, :string, required: true, description: "Issue ID to assign"

    field :working_copy_id, :string,
      required: true,
      description: "Working copy whose coding and QA team takes the issue"

    field :reason, :string,
      description: "Why the issue is moving, or the required correction instructions when rework is true"

    field :rework, :boolean,
      description:
        "Main or the operator requests corrections to a submitted fix on the same copy. " <>
          "Requires a reason and no open issue task; preserves completed task history."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         :ok <- may_request_rework(scope, frame, params),
         {:ok, issue} <-
           Agents.assign_issue_to_working_copy(
             scope,
             params.issue_id,
             params.working_copy_id,
             reason: params[:reason],
             rework: Map.get(params, :rework, false)
           ) do
      {:reply, IssuesMapper.issue_updated_response(issue, "assigned"), frame}
    else
      {:error, :not_found} -> {:reply, IssuesMapper.not_found_error(), frame}
      {:error, :no_team} -> {:reply, no_team_error(), frame}
      {:error, %Ecto.Changeset{} = cs} -> {:reply, IssuesMapper.validation_error(cs), frame}
      {:error, reason} -> {:reply, IssuesMapper.error(reason), frame}
    end
  end

  defp may_request_rework(scope, frame, %{rework: true}) do
    case frame.assigns[:agent_id] do
      nil ->
        :ok

      agent_id ->
        case Agents.fetch_agent(scope, agent_id) do
          {:ok, %{role: :main}} -> :ok
          _ -> {:error, "Only main or the operator may request issue corrections."}
        end
    end
  end

  defp may_request_rework(_scope, _frame, _params), do: :ok

  defp no_team_error do
    Response.tool()
    |> Response.error(
      "That working copy has no coding or QA agent to hold the issue. " <>
        "Staff the copy first, then assign the issue to it."
    )
  end
end
