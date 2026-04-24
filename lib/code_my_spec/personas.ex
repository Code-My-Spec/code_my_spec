defmodule CodeMySpec.Personas do
  @moduledoc """
  The Personas context.

  Delegates to either `PersonasRepository` (direct DB — server mode) or
  `RemoteClient` (HTTP API — CLI mode) depending on the
  `:personas_implementation` config key. Mirrors the Stories split.
  """

  alias CodeMySpec.Personas.Persona
  alias CodeMySpec.Personas.PersonasRepository
  alias CodeMySpec.Personas.PersonaStory

  defp impl do
    Application.get_env(:code_my_spec, :personas_implementation, PersonasRepository)
  end

  def create_persona(scope, attrs), do: impl().create_persona(scope, attrs)
  def update_persona(scope, persona, attrs), do: impl().update_persona(scope, persona, attrs)
  def list_personas(scope), do: impl().list_personas(scope)
  def get_persona(scope, id), do: impl().get_persona(scope, id)
  def get_persona_by_slug(scope, slug), do: impl().get_persona_by_slug(scope, slug)

  def link_persona_to_story(scope, persona_id, story_id),
    do: impl().link_persona_to_story(scope, persona_id, story_id)

  def unlink_persona_from_story(scope, persona_id, story_id),
    do: impl().unlink_persona_from_story(scope, persona_id, story_id)

  def list_personas_for_story(scope, story_id),
    do: impl().list_personas_for_story(scope, story_id)

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
