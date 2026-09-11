defmodule CodeMySpec.Personas.PersonasRepository do
  @moduledoc """
  Ecto queries for personas and persona_stories. All queries are scoped to the
  active project. Cross-project operations are rejected.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.Personas.Persona
  alias CodeMySpec.Personas.PersonaStory
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils

  @type attrs :: map()

  @spec create_persona(Scope.t(), attrs()) ::
          {:ok, Persona.t()} | {:error, :missing_active_project | Ecto.Changeset.t()}
  def create_persona(%Scope{active_project_id: project_id}, attrs)
      when not is_nil(project_id) do
    attrs = Map.put(Utils.normalize_keys(attrs), :project_id, project_id)

    %Persona{}
    |> Persona.changeset(attrs)
    |> Repo.insert()
  end

  def create_persona(%Scope{}, _attrs), do: {:error, :missing_active_project}

  @spec update_persona(Scope.t(), Persona.t(), attrs()) ::
          {:ok, Persona.t()}
          | {:error, :missing_active_project | :cross_project | Ecto.Changeset.t()}
  def update_persona(%Scope{active_project_id: project_id}, %Persona{} = persona, attrs)
      when not is_nil(project_id) do
    if persona.project_id == project_id do
      persona
      |> Persona.changeset(Map.delete(Utils.normalize_keys(attrs), :project_id))
      |> Repo.update()
    else
      {:error, :cross_project}
    end
  end

  def update_persona(%Scope{}, _persona, _attrs), do: {:error, :missing_active_project}

  @spec delete_persona(Scope.t(), Persona.t()) ::
          {:ok, Persona.t()}
          | {:error, :missing_active_project | :cross_project | Ecto.Changeset.t()}
  def delete_persona(%Scope{active_project_id: project_id}, %Persona{} = persona)
      when not is_nil(project_id) do
    if persona.project_id == project_id do
      from(ps in PersonaStory, where: ps.persona_id == ^persona.id)
      |> Repo.delete_all()

      Repo.delete(persona)
    else
      {:error, :cross_project}
    end
  end

  def delete_persona(%Scope{}, _persona), do: {:error, :missing_active_project}

  @spec list_personas(Scope.t()) :: [Persona.t()]
  def list_personas(%Scope{active_project_id: project_id}) when not is_nil(project_id) do
    Persona
    |> where([p], p.project_id == ^project_id)
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end

  def list_personas(%Scope{}), do: []

  @spec get_persona(Scope.t(), Ecto.UUID.t()) :: Persona.t() | nil
  def get_persona(%Scope{active_project_id: project_id}, id) when not is_nil(project_id) do
    Persona
    |> where([p], p.project_id == ^project_id and p.id == ^id)
    |> Repo.one()
  end

  def get_persona(%Scope{}, _id), do: nil

  @spec get_persona_by_slug(Scope.t(), String.t()) :: Persona.t() | nil
  def get_persona_by_slug(%Scope{active_project_id: project_id}, slug)
      when not is_nil(project_id) do
    Persona
    |> where([p], p.project_id == ^project_id and p.slug == ^slug)
    |> Repo.one()
  end

  def get_persona_by_slug(%Scope{}, _slug), do: nil

  @spec link_persona_to_story(Scope.t(), Ecto.UUID.t(), integer()) ::
          {:ok, PersonaStory.t()}
          | {:error, :missing_active_project | :cross_project | Ecto.Changeset.t()}
  def link_persona_to_story(%Scope{active_project_id: project_id} = scope, persona_id, story_id)
      when not is_nil(project_id) do
    with {:persona, %Persona{} = persona} <-
           {:persona, get_persona(scope, persona_id)},
         {:story, %Story{project_id: ^project_id}} <-
           {:story, Repo.get(Story, story_id)} do
      %PersonaStory{}
      |> PersonaStory.changeset(%{persona_id: persona.id, story_id: story_id})
      |> Repo.insert()
    else
      {:persona, nil} -> {:error, :cross_project}
      {:story, nil} -> {:error, :cross_project}
      {:story, %Story{}} -> {:error, :cross_project}
    end
  end

  def link_persona_to_story(%Scope{}, _persona_id, _story_id),
    do: {:error, :missing_active_project}

  @spec unlink_persona_from_story(Scope.t(), Ecto.UUID.t(), integer()) ::
          {:ok, :unlinked} | {:error, :missing_active_project | :not_found | :cross_project}
  def unlink_persona_from_story(
        %Scope{active_project_id: project_id} = scope,
        persona_id,
        story_id
      )
      when not is_nil(project_id) do
    case get_persona(scope, persona_id) do
      nil ->
        {:error, :cross_project}

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
    do: {:error, :missing_active_project}

  @spec list_stories_for_persona(Scope.t(), Ecto.UUID.t()) :: [Story.t()]
  def list_stories_for_persona(%Scope{active_project_id: project_id}, persona_id)
      when not is_nil(project_id) do
    from(s in Story,
      join: ps in PersonaStory,
      on: ps.story_id == s.id,
      where: s.project_id == ^project_id and ps.persona_id == ^persona_id,
      order_by: [asc: s.title]
    )
    |> Repo.all()
  end

  def list_stories_for_persona(%Scope{}, _persona_id), do: []

  @spec list_personas_for_story(Scope.t(), integer()) :: [Persona.t()]
  def list_personas_for_story(%Scope{active_project_id: project_id}, story_id)
      when not is_nil(project_id) do
    from(p in Persona,
      join: ps in PersonaStory,
      on: ps.persona_id == p.id,
      where: p.project_id == ^project_id and ps.story_id == ^story_id,
      order_by: [asc: p.name]
    )
    |> Repo.all()
  end

  def list_personas_for_story(%Scope{}, _story_id), do: []

  @spec list_personas_for_project(Scope.t(), integer()) :: [Persona.t()]
  def list_personas_for_project(%Scope{active_project_id: scope_project_id}, project_id)
      when not is_nil(scope_project_id) do
    if scope_project_id == project_id do
      Persona
      |> where([p], p.project_id == ^project_id)
      |> order_by([p], asc: p.name)
      |> Repo.all()
    else
      []
    end
  end

  def list_personas_for_project(%Scope{}, _project_id), do: []

  @doc """
  Returns {persona_id, story_id} pairs for every persona_stories row whose
  story belongs to the given project in the active scope.
  """
  @spec list_project_persona_story_links(Scope.t(), integer() | binary()) ::
          [{Ecto.UUID.t(), integer()}]
  def list_project_persona_story_links(%Scope{active_project_id: scope_project_id}, project_id)
      when not is_nil(scope_project_id) do
    if scope_project_id == project_id do
      from(ps in PersonaStory,
        join: s in Story,
        on: s.id == ps.story_id,
        where: s.project_id == ^project_id,
        select: {ps.persona_id, ps.story_id}
      )
      |> Repo.all()
    else
      []
    end
  end

  def list_project_persona_story_links(%Scope{}, _project_id), do: []
end
