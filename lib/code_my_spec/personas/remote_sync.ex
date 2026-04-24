defmodule CodeMySpec.Personas.RemoteSync do
  @moduledoc """
  Pulls personas from the remote API and upserts them into the local database,
  then reconciles `persona_stories` links for the active project against the
  server's authoritative edge list.

  `PersonasChecker.complete?/2` reads the local DB directly. Without this
  sync, agents creating personas through `Personas.RemoteClient` would have
  the records on the server but no local-visible state, and the checker would
  report "no personas" until the CLI saw them.

  Mirrors `Stories.RemoteSync` — same shape, same pattern.
  """

  require Logger

  import Ecto.Query

  alias CodeMySpec.Auth.OAuthClient
  alias CodeMySpec.Personas.Persona
  alias CodeMySpec.Personas.PersonaStory
  alias CodeMySpec.Personas.RemoteClient
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @doc """
  Fetches personas from the remote API and upserts them locally along with
  their persona_stories links for the active project.

  Acquires the auth token up front so missing/expired tokens surface as a
  `{:error, reason}` tuple rather than raising inside the HTTP client.
  """
  @spec sync(Scope.t(), keyword()) :: :ok | {:error, term()}
  def sync(%Scope{active_project_id: project_id} = scope, opts \\ [])
      when is_binary(project_id) do
    with {:ok, token} <- OAuthClient.get_token(),
         client_opts = Keyword.put(opts, :token, token),
         personas <- RemoteClient.list_personas(scope, client_opts),
         edges <-
           RemoteClient.list_project_persona_story_links(scope, project_id, client_opts) do
      Logger.debug(
        "[Personas.RemoteSync] Upserting #{length(personas)} personas from remote; " <>
          "reconciling #{length(edges)} link edges for project #{project_id}"
      )

      Enum.each(personas, &upsert_persona(&1, scope))
      sync_project_links(edges, project_id)
      :ok
    end
  end

  defp upsert_persona(%Persona{} = persona, scope) do
    attrs = %{
      slug: persona.slug,
      name: persona.name,
      headline: persona.headline,
      persona_type: persona.persona_type,
      account_id: persona.account_id || scope.active_account_id
    }

    %Persona{id: persona.id}
    |> Persona.changeset(attrs)
    |> Ecto.Changeset.put_change(:account_id, persona.account_id || scope.active_account_id)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :id
    )
  end

  # Rebuild the persona_stories rows for the project against the server's
  # authoritative edge list. Full refresh, scoped by project — other
  # projects' links are untouched.
  defp sync_project_links(server_edges, project_id) do
    local_edges = local_edges_for_project(project_id)
    server_set = MapSet.new(server_edges)
    local_set = MapSet.new(local_edges)

    to_delete = MapSet.difference(local_set, server_set)
    to_insert = MapSet.difference(server_set, local_set)

    delete_edges(to_delete)
    insert_edges(to_insert)
    :ok
  end

  defp local_edges_for_project(project_id) do
    from(ps in PersonaStory,
      join: s in Story,
      on: s.id == ps.story_id,
      where: s.project_id == ^project_id,
      select: {ps.persona_id, ps.story_id}
    )
    |> Repo.all()
  end

  defp delete_edges(edges) do
    Enum.each(edges, fn {persona_id, story_id} ->
      query =
        from(ps in PersonaStory,
          where: ps.persona_id == ^persona_id and ps.story_id == ^story_id
        )

      Repo.delete_all(query)
    end)
  end

  defp insert_edges(edges) do
    Enum.each(edges, fn {persona_id, story_id} ->
      %PersonaStory{}
      |> PersonaStory.changeset(%{persona_id: persona_id, story_id: story_id})
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:persona_id, :story_id])
    end)
  end
end
