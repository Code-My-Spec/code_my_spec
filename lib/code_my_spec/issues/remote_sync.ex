defmodule CodeMySpec.Issues.RemoteSync do
  @moduledoc """
  Pulls accepted issues from the remote API and upserts them into the local database.
  """

  require Logger

  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Issues.RemoteClient
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @spec sync(Scope.t()) :: :ok | {:error, term()}
  def sync(%Scope{} = scope) do
    client = RemoteClient.new(scope)

    case RemoteClient.list_accepted_issues(client) do
      {:ok, %{status: 200, body: %{"data" => issues}}} ->
        remote_issues = Enum.map(issues, &RemoteClient.deserialize_issue/1)
        Logger.debug("[IssuesRemoteSync] Upserting #{length(remote_issues)} issues from remote")
        Enum.each(remote_issues, &upsert_issue/1)
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[IssuesRemoteSync] Unexpected status: #{status}, body: #{inspect(body)}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.warning("[IssuesRemoteSync] Failed to fetch remote issues: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp upsert_issue(%Issue{} = issue) do
    attrs = %{
      title: issue.title,
      severity: issue.severity,
      scope: issue.scope,
      description: issue.description,
      source: issue.source,
      status: issue.status,
      resolution: issue.resolution,
      story_id: issue.story_id,
      source_path: issue.source_path,
      project_id: issue.project_id,
      account_id: issue.account_id
    }

    %Issue{id: issue.id}
    |> Issue.changeset(attrs)
    |> Ecto.Changeset.put_change(:project_id, issue.project_id)
    |> Ecto.Changeset.put_change(:account_id, issue.account_id)
    |> Ecto.Changeset.put_change(:status, issue.status)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :id
    )
  rescue
    e ->
      Logger.warning("[IssuesRemoteSync] Failed to upsert issue #{issue.id}: #{Exception.message(e)}")
  end
end
