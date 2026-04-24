defmodule CodeMySpec.Personas.PersonasRepository do
  @moduledoc """
  Ecto queries for personas and persona_stories. All queries are scoped to the
  active account. Cross-account operations are rejected.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Personas.Persona
  alias CodeMySpec.Personas.PersonaStory
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @type attrs :: map()

  @spec create_persona(Scope.t(), attrs()) ::
          {:ok, Persona.t()} | {:error, :missing_active_account | Ecto.Changeset.t()}
  def create_persona(%Scope{active_account_id: account_id}, attrs)
      when not is_nil(account_id) do
    attrs = Map.put(normalize(attrs), :account_id, account_id)

    %Persona{}
    |> Persona.changeset(attrs)
    |> Repo.insert()
  end

  def create_persona(%Scope{}, _attrs), do: {:error, :missing_active_account}

  @spec update_persona(Scope.t(), Persona.t(), attrs()) ::
          {:ok, Persona.t()} | {:error, :missing_active_account | :cross_account | Ecto.Changeset.t()}
  def update_persona(%Scope{active_account_id: account_id}, %Persona{} = persona, attrs)
      when not is_nil(account_id) do
    if persona.account_id == account_id do
      persona
      |> Persona.changeset(Map.delete(normalize(attrs), :account_id))
      |> Repo.update()
    else
      {:error, :cross_account}
    end
  end

  def update_persona(%Scope{}, _persona, _attrs), do: {:error, :missing_active_account}

  @spec list_personas(Scope.t()) :: [Persona.t()]
  def list_personas(%Scope{active_account_id: account_id}) when not is_nil(account_id) do
    Persona
    |> where([p], p.account_id == ^account_id)
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end

  def list_personas(%Scope{}), do: []

  @spec get_persona(Scope.t(), Ecto.UUID.t()) :: Persona.t() | nil
  def get_persona(%Scope{active_account_id: account_id}, id) when not is_nil(account_id) do
    Persona
    |> where([p], p.account_id == ^account_id and p.id == ^id)
    |> Repo.one()
  end

  def get_persona(%Scope{}, _id), do: nil

  @spec get_persona_by_slug(Scope.t(), String.t()) :: Persona.t() | nil
  def get_persona_by_slug(%Scope{active_account_id: account_id}, slug)
      when not is_nil(account_id) do
    Persona
    |> where([p], p.account_id == ^account_id and p.slug == ^slug)
    |> Repo.one()
  end

  def get_persona_by_slug(%Scope{}, _slug), do: nil

  @spec link_persona_to_story(Scope.t(), Ecto.UUID.t(), integer()) ::
          {:ok, PersonaStory.t()}
          | {:error, :missing_active_account | :cross_account | Ecto.Changeset.t()}
  def link_persona_to_story(%Scope{active_account_id: account_id}, persona_id, story_id)
      when not is_nil(account_id) do
    with {:persona, %Persona{} = persona} <-
           {:persona, get_persona(%Scope{active_account_id: account_id}, persona_id)},
         {:story, %Story{account_id: ^account_id}} <-
           {:story, Repo.get(Story, story_id)} do
      %PersonaStory{}
      |> PersonaStory.changeset(%{persona_id: persona.id, story_id: story_id})
      |> Repo.insert()
    else
      {:persona, nil} -> {:error, :cross_account}
      {:story, nil} -> {:error, :cross_account}
      {:story, %Story{}} -> {:error, :cross_account}
    end
  end

  def link_persona_to_story(%Scope{}, _persona_id, _story_id),
    do: {:error, :missing_active_account}

  @spec unlink_persona_from_story(Scope.t(), Ecto.UUID.t(), integer()) ::
          {:ok, :unlinked} | {:error, :missing_active_account | :not_found | :cross_account}
  def unlink_persona_from_story(%Scope{active_account_id: account_id}, persona_id, story_id)
      when not is_nil(account_id) do
    case get_persona(%Scope{active_account_id: account_id}, persona_id) do
      nil ->
        {:error, :cross_account}

      %Persona{id: pid} ->
        query =
          from ps in PersonaStory,
            where: ps.persona_id == ^pid and ps.story_id == ^story_id

        case Repo.delete_all(query) do
          {0, _} -> {:error, :not_found}
          {_n, _} -> {:ok, :unlinked}
        end
    end
  end

  def unlink_persona_from_story(%Scope{}, _persona_id, _story_id),
    do: {:error, :missing_active_account}

  @spec list_personas_for_story(Scope.t(), integer()) :: [Persona.t()]
  def list_personas_for_story(%Scope{active_account_id: account_id}, story_id)
      when not is_nil(account_id) do
    from(p in Persona,
      join: ps in PersonaStory,
      on: ps.persona_id == p.id,
      where: p.account_id == ^account_id and ps.story_id == ^story_id,
      order_by: [asc: p.name]
    )
    |> Repo.all()
  end

  def list_personas_for_story(%Scope{}, _story_id), do: []

  @spec list_personas_for_project(Scope.t(), integer()) :: [Persona.t()]
  def list_personas_for_project(%Scope{active_account_id: account_id}, project_id)
      when not is_nil(account_id) do
    from(p in Persona,
      join: ps in PersonaStory,
      on: ps.persona_id == p.id,
      join: s in Story,
      on: s.id == ps.story_id,
      where: p.account_id == ^account_id and s.project_id == ^project_id,
      distinct: true,
      order_by: [asc: p.name]
    )
    |> Repo.all()
  end

  def list_personas_for_project(%Scope{}, _project_id), do: []

  @doc """
  Returns {persona_id, story_id} pairs for every persona_stories row whose
  story belongs to the given project in the active account. Used by
  `Personas.RemoteSync` to replay link edges into the local DB.
  """
  @spec list_project_persona_story_links(Scope.t(), integer() | binary()) ::
          [{Ecto.UUID.t(), integer()}]
  def list_project_persona_story_links(%Scope{active_account_id: account_id}, project_id)
      when not is_nil(account_id) do
    from(ps in PersonaStory,
      join: s in Story,
      on: s.id == ps.story_id,
      where: s.project_id == ^project_id and s.account_id == ^account_id,
      select: {ps.persona_id, ps.story_id}
    )
    |> Repo.all()
  end

  def list_project_persona_story_links(%Scope{}, _project_id), do: []

  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  rescue
    ArgumentError -> attrs
  end
end
