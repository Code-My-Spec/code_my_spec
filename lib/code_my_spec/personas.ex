defmodule CodeMySpec.Personas do
  @moduledoc """
  The Personas context.

  Direct-DB implementation via `PersonasRepository`. The
  `:personas_implementation` config key is kept as a swap point for test
  doubles.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Paths,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Stories,
      CodeMySpec.Users,
      CodeMySpec.Utils
    ],
    exports: :all

  alias CodeMySpec.Personas.Persona
  alias CodeMySpec.Personas.PersonasRepository
  alias CodeMySpec.Personas.PersonaStory
  alias CodeMySpec.Requirements.GraphInputs
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
    key = scope.active_project_id
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "project:#{key}:personas")
  end

  defp broadcast(%Scope{} = scope, message) do
    key = scope.active_project_id
    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, "project:#{key}:personas", message)

    GraphInputs.announce(scope, "Personas", graph_entities(message))
  end

  # `:project` on everything, because `personas_complete` is a project
  # requirement and reads every persona and its artifacts.
  #
  # The story as well when a link moved, because `Freshness.story/2` hashes
  # `personas_by_story` and `three_amigos_complete` gates on a story having one.
  # `Preloader.persona_story_links/1` calls that join table "the worst thing to
  # leave out" — creating a persona used to invalidate the graph while *linking*
  # one did not, so a story became eligible for its Three Amigos and the cached
  # graph went on saying it was not.
  #
  # A new persona has no links yet, so it moves the project requirement and no
  # story.
  #
  # An updated or deleted persona names nothing and so records `:unknown`,
  # recomputing everything. Deliberate: by the time the delete broadcasts, its
  # `persona_stories` rows have already cascaded away, so the stories it
  # affected are exactly what can no longer be asked for. Narrowing that means
  # capturing the links before the write, which is a change to the delete path
  # rather than to this function.
  defp graph_entities({:persona_linked, %{story_id: story_id}}) when not is_nil(story_id),
    do: [{"story", story_id}, :project]

  defp graph_entities({:persona_unlinked, %{story_id: story_id}}) when not is_nil(story_id),
    do: [{"story", story_id}, :project]

  defp graph_entities({:persona_created, _persona}), do: [:project]

  defp graph_entities(_message), do: []

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
    Path.join(CodeMySpec.Paths.personas_dir(), slug)
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
