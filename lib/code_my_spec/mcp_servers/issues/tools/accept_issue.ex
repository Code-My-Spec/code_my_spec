defmodule CodeMySpec.McpServers.Issues.Tools.AcceptIssue do
  @moduledoc """
  Accepts an incoming issue for triage.

  Transitions the issue from incoming → accepted.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :issue_id, :string, required: true, doc: "Issue ID to accept"
    field :story_id, :integer, doc: "Optional story ID to link this issue to"

    field :category, :string,
      doc: "Disposition category: 'bug' (default) or 'requirements_change' (requires story_id)"
  end

  @impl true
  def execute(params, frame) do
    opts =
      []
      |> maybe_put(:story_id, params[:story_id])
      |> maybe_put(:category, parse_category(params[:category]))

    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         issue when not is_nil(issue) <- Issues.get_issue(scope, params.issue_id),
         {:ok, updated} <- Issues.accept_issue(scope, issue, opts) do
      {:reply, IssuesMapper.issue_updated_response(updated, "accepted"), frame}
    else
      nil -> {:reply, IssuesMapper.not_found_error(), frame}
      {:error, %Ecto.Changeset{} = cs} -> {:reply, IssuesMapper.validation_error(cs), frame}
      {:error, reason} -> {:reply, IssuesMapper.error(reason), frame}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_category(nil), do: nil
  defp parse_category("bug"), do: :bug
  defp parse_category("requirements_change"), do: :requirements_change
  defp parse_category(other) when is_atom(other), do: other
  defp parse_category(_), do: nil
end
