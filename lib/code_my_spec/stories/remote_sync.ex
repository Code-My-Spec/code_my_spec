defmodule CodeMySpec.Stories.RemoteSync do
  @moduledoc """
  Pulls stories from the remote API and upserts them into the local database.
  """

  require Logger

  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.RemoteClient
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @doc """
  Fetches stories from the remote API and upserts them locally.
  """
  @spec sync(Scope.t()) :: :ok | {:error, term()}
  def sync(%Scope{} = scope) do
    client = RemoteClient.new(scope)

    case RemoteClient.list_project_stories(client) do
      {:ok, %{status: 200, body: %{"data" => stories}}} ->
        remote_stories = Enum.map(stories, &RemoteClient.deserialize_story/1)
        Logger.debug("[RemoteSync] Upserting #{length(remote_stories)} stories from remote")
        Enum.each(remote_stories, &upsert_story(&1, scope))
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[RemoteSync] Unexpected status: #{status}, body: #{inspect(body)}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        Logger.warning("[RemoteSync] Failed to fetch remote stories: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp upsert_story(%Story{} = story, scope) do
    project_id = story.project_id || scope.active_project_id

    attrs = %{
      title: story.title,
      description: story.description,
      status: story.status,
      priority: story.priority,
      locked_at: story.locked_at,
      lock_expires_at: story.lock_expires_at,
      locked_by: story.locked_by,
      project_id: project_id,
      component_id: story.component_id,
      account_id: story.account_id || scope.active_account_id
    }

    case %Story{id: story.id}
         |> Story.changeset(attrs)
         |> Repo.insert(
           on_conflict: {:replace_all_except, [:id, :inserted_at]},
           conflict_target: :id
         ) do
      {:ok, _} ->
        upsert_criteria(story.criteria || [], project_id)

      {:error, changeset} ->
        Logger.warning("[RemoteSync] Failed to upsert story #{story.id}: #{inspect(changeset.errors)}")
    end
  rescue
    e ->
      Logger.warning("[RemoteSync] Failed to upsert story #{story.id}: #{Exception.message(e)}")
  end

  defp upsert_criteria([], _project_id), do: :ok

  defp upsert_criteria(criteria, project_id) do
    Enum.each(criteria, fn %Criterion{} = criterion ->
      attrs = %{
        description: criterion.description,
        verified: criterion.verified,
        verified_at: criterion.verified_at,
        story_id: criterion.story_id,
        project_id: criterion.project_id || project_id
      }

      case %Criterion{id: criterion.id}
           |> Criterion.changeset(attrs)
           |> Repo.insert(
             on_conflict: {:replace_all_except, [:id, :inserted_at]},
             conflict_target: :id
           ) do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          Logger.warning(
            "[RemoteSync] Failed to upsert criterion #{criterion.id}: #{inspect(changeset.errors)}"
          )
      end
    end)
  end
end
