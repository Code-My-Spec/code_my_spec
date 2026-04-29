defmodule CodeMySpec.Stories.RemoteSync do
  @moduledoc """
  Pulls stories from the remote API and upserts them into the local database.
  """

  require Logger

  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.RemoteClient
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @doc """
  Fetches stories from the remote API and upserts them locally.

  Acquires the auth token up front and passes it to the client so a
  missing/expired token surfaces as an `{:error, reason}` tuple rather
  than a raise deep inside the HTTP client.
  """
  @spec sync(Scope.t(), keyword()) :: :ok | {:error, term()}
  def sync(%Scope{} = scope, opts \\ []) do
    with {:ok, token} <- OAuthClient.get_token(),
         {:ok, stories} <-
           RemoteClient.list_project_stories(scope, Keyword.put(opts, :token, token)) do
      Logger.debug("[RemoteSync] Upserting #{length(stories)} stories from remote")

      # Per-record isolation: a single bad record (FK violation, type cast
      # error, etc.) shouldn't take down the whole sync. Each upsert runs
      # in its own task; if it crashes, we log and move on. SQLite is
      # single-writer, so max_concurrency stays at 1.
      stories
      |> Task.async_stream(&upsert_story(&1, scope),
        max_concurrency: 1,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.each(fn
        {:ok, _} ->
          :ok

        {:exit, reason} ->
          Logger.warning("[RemoteSync] Story upsert task crashed: #{inspect(reason)}")
      end)

      :ok
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
         |> Ecto.Changeset.put_change(:account_id, story.account_id || scope.active_account_id)
         |> Repo.insert(
           on_conflict: {:replace_all_except, [:id, :inserted_at]},
           conflict_target: :id
         ) do
      {:ok, _} = ok ->
        upsert_criteria(story.criteria || [], project_id)
        ok

      {:error, changeset} = error ->
        Logger.warning(
          "[RemoteSync] Failed to upsert story #{story.id}: #{inspect(changeset.errors)}"
        )

        error
    end
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
