defmodule CodeMySpec.Stories.RemoteSync do
  @moduledoc """
  Pulls stories from the remote API and upserts them into the local database.
  """

  require Logger

  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.RemoteClient
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @doc """
  Fetches stories from the remote API and upserts them locally.
  """
  @spec sync(Scope.t()) :: :ok | {:error, term()}
  def sync(%Scope{} = scope) do
    case RemoteClient.list_project_stories(scope) do
      {:ok, remote_stories} ->
        Logger.info("[RemoteSync] Upserting #{length(remote_stories)} stories from remote")
        Enum.each(remote_stories, &upsert_story(&1, scope))
        :ok

      {:error, reason} ->
        Logger.warning("[RemoteSync] Failed to fetch remote stories: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp upsert_story(%Story{} = story, scope) do
    attrs = %{
      title: story.title,
      description: story.description,
      acceptance_criteria: story.acceptance_criteria,
      status: story.status,
      priority: story.priority,
      locked_at: story.locked_at,
      lock_expires_at: story.lock_expires_at,
      locked_by: story.locked_by,
      project_id: story.project_id || scope.active_project_id,
      component_id: story.component_id,
      account_id: story.account_id || scope.active_account_id
    }

    %Story{id: story.id}
    |> Story.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :id
    )
  rescue
    e ->
      Logger.warning("[RemoteSync] Failed to upsert story #{story.id}: #{Exception.message(e)}")
  end
end
