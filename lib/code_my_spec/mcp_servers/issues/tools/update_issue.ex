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

  Allowed fields: `severity`, `story_id`, `category`, `source_path`,
  and `append`.

  ## Why `append` and not `description`

  An agent files an issue at the moment it has the evidence, which is
  often before it understands the defect — and that is the right time
  to file, because the evidence is perishable. So reports go stale,
  and until now the only remedy was another issue: `1f60a145` cited
  `server.log` for a stop hook that posts to :4004 and logs to
  `web.log`, which sent its reader to a process that was not involved
  and a log showing no activity. Correcting it took a second issue,
  `b0486568`, and the queue then held two reports of one defect with
  the first still misleading whoever picked it up.

  This appends rather than replacing, because issue bodies are written
  by whichever agent was there and a later reader needs to see what
  was originally claimed as well as what turned out to be true. A
  correction that quietly rewrites the first account destroys the one
  thing that makes the sequence legible.

  Status transitions still go through `accept_issue` / `dismiss_issue`
  / `resolve_issue`.
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

    field :append, :string,
      doc:
        "Add a correction or later evidence to the end of the issue body. " <>
          "The original text is kept — use this instead of filing a second issue " <>
          "to correct a first."
  end

  @impl true
  def execute(params, frame) do
    attrs = build_attrs(params)

    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         :ok <- ensure_some_field(attrs, params[:append]),
         issue when not is_nil(issue) <- Issues.get_issue(scope, params.issue_id),
         attrs = maybe_append(attrs, issue, params[:append]),
         {:ok, updated} <- Issues.update_issue(scope, issue, attrs) do
      {:reply, IssuesMapper.issue_updated_response(updated, "updated"), frame}
    else
      :empty ->
        {:reply,
         IssuesMapper.error(
           "No updatable fields provided. Pass at least one of: severity, story_id, " <>
             "category, source_path, append."
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

  defp ensure_some_field(attrs, append) do
    if map_size(attrs) > 0 or present?(append), do: :ok, else: :empty
  end

  # Under a rule rather than at the end of the body, so a reader can see at a
  # glance that what follows was not part of the original report. Kept in the
  # same field because that is what every consumer already reads — a separate
  # corrections table would leave `list_issues` and the triage prompt showing
  # the uncorrected text, which is the failure this is fixing.
  defp maybe_append(attrs, issue, append) do
    if present?(append) do
      stamped = """
      #{issue.description}

      ---

      **Correction / later evidence — #{DateTime.utc_now() |> DateTime.to_iso8601()}**

      #{String.trim(append)}
      """

      Map.put(attrs, :description, stamped)
    else
      attrs
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

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
