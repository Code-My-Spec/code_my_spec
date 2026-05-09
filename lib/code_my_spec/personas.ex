defmodule CodeMySpec.Personas do
  @moduledoc """
  The Personas context.

  Direct-DB implementation via `PersonasRepository`. The
  `:personas_implementation` config key is kept as a swap point for test
  doubles.
  """

  alias CodeMySpec.Personas.Persona
  alias CodeMySpec.Personas.PersonasRepository
  alias CodeMySpec.Personas.PersonaStory
  alias CodeMySpec.Users.Scope

  defp impl do
    Application.get_env(:code_my_spec, :personas_implementation, PersonasRepository)
  end

  @doc """
  Subscribes to scoped notifications about persona changes.

  Broadcasts match the pattern:

    * {:persona_created, %Persona{}}
    * {:persona_updated, %Persona{}}
    * {:persona_deleted, %Persona{}}
    * {:persona_linked, %PersonaStory{}}
    * {:persona_unlinked, %{persona_id: _, story_id: _}}

  """
  def subscribe(%Scope{} = scope) do
    key = scope.active_account_id
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{key}:personas")
  end

  defp broadcast(%Scope{} = scope, message) do
    key = scope.active_account_id
    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, "user:#{key}:personas", message)
  end

  def create_persona(scope, attrs) do
    case impl().create_persona(scope, attrs) do
      {:ok, persona} = ok ->
        broadcast(scope, {:persona_created, persona})
        ok

      other ->
        other
    end
  end

  def update_persona(scope, persona, attrs) do
    case impl().update_persona(scope, persona, attrs) do
      {:ok, updated} = ok ->
        broadcast(scope, {:persona_updated, updated})
        ok

      other ->
        other
    end
  end

  def delete_persona(scope, persona) do
    case impl().delete_persona(scope, persona) do
      {:ok, deleted} = ok ->
        broadcast(scope, {:persona_deleted, deleted})
        ok

      other ->
        other
    end
  end

  def list_personas(scope), do: impl().list_personas(scope)
  def get_persona(scope, id), do: impl().get_persona(scope, id)
  def get_persona_by_slug(scope, slug), do: impl().get_persona_by_slug(scope, slug)

  def link_persona_to_story(scope, persona_id, story_id) do
    case impl().link_persona_to_story(scope, persona_id, story_id) do
      {:ok, link} = ok ->
        broadcast(scope, {:persona_linked, link})
        ok

      other ->
        other
    end
  end

  def unlink_persona_from_story(scope, persona_id, story_id) do
    case impl().unlink_persona_from_story(scope, persona_id, story_id) do
      {:ok, :unlinked} = ok ->
        broadcast(
          scope,
          {:persona_unlinked, %{persona_id: persona_id, story_id: story_id}}
        )

        ok

      other ->
        other
    end
  end

  def list_personas_for_story(scope, story_id),
    do: impl().list_personas_for_story(scope, story_id)

  def list_stories_for_persona(scope, persona_id),
    do: impl().list_stories_for_persona(scope, persona_id)

  def list_personas_for_project(scope, project_id),
    do: impl().list_personas_for_project(scope, project_id)

  def list_project_persona_story_links(scope, project_id),
    do: impl().list_project_persona_story_links(scope, project_id)

  @doc """
  Returns the persona folder path for the given slug.
  """
  @spec persona_folder(String.t()) :: String.t()
  def persona_folder(slug) when is_binary(slug) do
    ".code_my_spec/personas/#{slug}"
  end

  @doc "Returns the summary.md path for the given slug."
  @spec summary_path(String.t()) :: String.t()
  def summary_path(slug), do: Path.join(persona_folder(slug), "summary.md")

  @doc "Returns the sources.md path for the given slug."
  @spec sources_path(String.t()) :: String.t()
  def sources_path(slug), do: Path.join(persona_folder(slug), "sources.md")

  @spec persona_module :: module()
  def persona_module, do: Persona

  @spec persona_story_module :: module()
  def persona_story_module, do: PersonaStory
end
