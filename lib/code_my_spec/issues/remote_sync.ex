defmodule CodeMySpec.Issues.RemoteSync do
  @moduledoc """
  Pulls accepted issues from the remote API and upserts them into the local database.
  """

  require Logger

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.Issues.RemoteClient
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @spec sync(Scope.t(), keyword()) :: :ok | {:error, term()}
  def sync(%Scope{} = scope, opts \\ []) do
    with {:ok, token} <- OAuthClient.get_token(),
         {:ok, issues} <-
           RemoteClient.list_accepted_issues(scope, Keyword.put(opts, :token, token)) do
      Logger.debug("[IssuesRemoteSync] Upserting #{length(issues)} issues from remote")
      Enum.each(issues, &upsert_issue/1)
      :ok
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
