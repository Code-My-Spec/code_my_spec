defmodule CodeMySpec.McpServers.Issues.Tools.UpdateIssue do
  @moduledoc """
  Update non-status fields on an existing issue.

  Use this for re-triage decisions that don't change the issue's
  status — most commonly severity adjustments after a closer look
  at the body, or moving an issue under the right story / category
  after the original report misclassified it.

  Status transitions (incoming → accepted / dismissed, accepted →
  resolved) go through the dedicated `accept_issue` / `dismiss_issue`
  / `resolve_issue` tools — those flows enforce transition rules
  this tool deliberately skips.

  Allowed fields: `severity`, `story_id`, `category`, `source_path`.
  Other fields are ignored. The update is pushed to the remote
  server first (when the issue is mirrored) and only persists
  locally if the remote push succeeds — same fail-loud pattern
  as the disposition tools.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.IssuesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :issue_id, :string, required: true, doc: "Issue ID to update"

    field :severity, :string,
      doc: "New severity: critical, high, medium, low, or info"

    field :story_id, :integer, doc: "Re-link the issue to this story id"

    field :category, :string,
      doc: "Re-categorize: 'bug' or 'requirements_change'"

    field :source_path, :string, doc: "Update the source file path"
  end

  @impl true
  def execute(params, frame) do
    attrs = build_attrs(params)

    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         :ok <- ensure_some_field(attrs),
         issue when not is_nil(issue) <- Issues.get_issue(scope, params.issue_id),
         {:ok, updated} <- Issues.update_issue(scope, issue, attrs) do
      {:reply, IssuesMapper.issue_updated_response(updated, "updated"), frame}
    else
      :empty ->
        {:reply,
         IssuesMapper.error(
           "No updatable fields provided. Pass at least one of: severity, story_id, category, source_path."
         ), frame}

      nil ->
        {:reply, IssuesMapper.not_found_error(), frame}

      {:error, %Ecto.Changeset{} = cs} ->
        {:reply, IssuesMapper.validation_error(cs), frame}

      {:error, reason} ->
        {:reply, IssuesMapper.error(reason), frame}
    end
  end

  defp build_attrs(params) do
    %{}
    |> maybe_put(:severity, parse_severity(params[:severity]))
    |> maybe_put(:story_id, params[:story_id])
    |> maybe_put(:category, parse_category(params[:category]))
    |> maybe_put(:source_path, params[:source_path])
  end

  defp ensure_some_field(attrs) when map_size(attrs) > 0, do: :ok
  defp ensure_some_field(_), do: :empty

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_severity(nil), do: nil

  defp parse_severity(value) when is_binary(value) do
    case String.downcase(value) do
      sev when sev in ~w(critical high medium low info) -> String.to_atom(sev)
      _ -> nil
    end
  end

  defp parse_category(nil), do: nil
  defp parse_category("bug"), do: :bug
  defp parse_category("requirements_change"), do: :requirements_change
  defp parse_category(other) when is_atom(other), do: other
  defp parse_category(_), do: nil
end
