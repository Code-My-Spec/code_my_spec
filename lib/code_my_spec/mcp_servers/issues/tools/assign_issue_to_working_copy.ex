defmodule CodeMySpec.McpServers.Issues.Tools.AssignIssueToWorkingCopy do
  @moduledoc """
  Assigns an issue to a working copy's coding and QA team.

  Both team members are bound to the issue: the coder is offered its fix
  ahead of any other eligible work, and QA is offered testing it once the
  fix is submitted. Assigning an issue already bound to another copy moves
  it — and its open task — to this one, freeing the old team.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :issue_id, :string, required: true, doc: "Issue ID to assign"

    field :working_copy_id, :string,
      required: true,
      doc: "Working copy whose coding and QA team takes the issue"

    field :reason, :string,
      doc: "Why the issue is moving, when reassigning it away from another team"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, issue} <-
           Agents.assign_issue_to_working_copy(
             scope,
             params.issue_id,
             params.working_copy_id,
             reason: params[:reason]
           ) do
      {:reply, IssuesMapper.issue_updated_response(issue, "assigned"), frame}
    else
      {:error, :not_found} -> {:reply, IssuesMapper.not_found_error(), frame}
      {:error, :no_team} -> {:reply, no_team_error(), frame}
      {:error, %Ecto.Changeset{} = cs} -> {:reply, IssuesMapper.validation_error(cs), frame}
      {:error, reason} -> {:reply, IssuesMapper.error(reason), frame}
    end
  end

  defp no_team_error do
    Response.tool()
    |> Response.error(
      "That working copy has no coding or QA agent to hold the issue. " <>
        "Staff the copy first, then assign the issue to it."
    )
  end
end
