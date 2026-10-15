defmodule CodeMySpec.Personas.Tools do
  @moduledoc """
  The persona tools an agent calls, and the text they answer in.
  """

  alias CodeMySpec.Personas
  alias CodeMySpec.Tools

  @doc "Every persona tool, for `CodeMySpec.ToolLibrary`."
  def all do
    [
      __MODULE__.CreatePersona,
      __MODULE__.UpdatePersona,
      __MODULE__.DeletePersona,
      __MODULE__.LinkPersonaToStory,
      __MODULE__.UnlinkPersonaFromStory,
      __MODULE__.ListPersonas,
      __MODULE__.GetPersona
    ]
  end

  @doc "A persona by `persona_id`, else by `slug`."
  def fetch_persona(scope, %{persona_id: id}) when is_binary(id) and id != "",
    do: found(Personas.get_persona(scope, id))

  def fetch_persona(scope, %{slug: slug}) when is_binary(slug) and slug != "",
    do: found(Personas.get_persona_by_slug(scope, slug))

  def fetch_persona(_scope, _params), do: {:error, :missing_identifier}

  defp found(nil), do: {:error, :not_found}
  defp found(persona), do: {:ok, persona}

  @doc """
  One persona. `:heading` because `get_persona` reaches this too, and a fetch
  that answered "Persona created:" reported an event that did not happen.
  """
  def persona_text(persona, opts \\ []) do
    heading = Keyword.get(opts, :heading, "Persona created")

    """
    #{heading}: "#{persona.name}" (slug: `#{persona.slug}`, id: `#{persona.id}`)

    Type: `#{persona.persona_type}` — #{persona_type_note(persona.persona_type)}

    Next steps, if not already done:
    - Write `.code_my_spec/personas/#{persona.slug}/summary.md` with required sections (Role, Goals, Pain Points, Context, Decision Drivers, Evidence).
    - Write `.code_my_spec/personas/#{persona.slug}/sources.md` with URL + title + access date per entry.
    - Call `link_persona_to_story` with persona_id `#{persona.id}` and the story_number of a story this persona applies to.
    """
    |> String.trim()
  end

  defp persona_type_note(:proto),
    do:
      "hypothesis from desk research. Treat all claims as provisional and validate with real users before load-bearing decisions depend on them."

  defp persona_type_note(:qualitative),
    do: "backed by 5–30 coded user interviews. Trustworthy for feature design and prioritization."

  defp persona_type_note(:statistical),
    do: "backed by survey + cluster analysis. Trustworthy for strategic and investment decisions."

  defp persona_type_note(_), do: "unknown tier — check the database schema for valid values."

  def link_text(persona_story, story),
    do:
      "Persona linked: persona_id `#{persona_story.persona_id}` ↔ story #{story.number} (\"#{story.title}\")."

  def unlink_text(persona_id, story),
    do:
      "Persona unlinked: persona_id `#{persona_id}` ↮ story #{story.number} (\"#{story.title}\")."

  def update_text(persona) do
    headline = (persona.headline && "\nHeadline: #{persona.headline}") || ""

    """
    Persona updated: "#{persona.name}" (slug: `#{persona.slug}`, id: `#{persona.id}`, type: `#{persona.persona_type}`).#{headline}
    """
    |> String.trim()
  end

  def delete_text(persona),
    do:
      "Persona deleted: \"#{persona.name}\" (slug: `#{persona.slug}`, id: `#{persona.id}`). All `persona_stories` links removed."

  def list_text([]) do
    "No personas on this project yet. Run a persona research session to create one — " <>
      "see `start_task` with requirement `personas_complete`."
  end

  def list_text(personas) do
    lines =
      Enum.map_join(personas, "\n", fn p ->
        headline = (p.headline && " — #{p.headline}") || ""
        "- **#{p.name}** (slug: `#{p.slug}`, id: `#{p.id}`, type: `#{p.persona_type}`)#{headline}"
      end)

    "Personas on this project (#{length(personas)}):\n\n#{lines}"
  end

  @doc "Why a call failed, as the agent is told it; reasons not a persona's go to `Tools.error/1`."
  def error(:not_found), do: {:error, "Persona not found on the active project."}

  def error(:missing_identifier), do: {:error, "must provide either 'slug' or 'persona_id'"}

  def error(:cross_project),
    do:
      {:error,
       "Cross-project operation rejected. The persona or story does not belong to the active project."}

  def error(reason), do: Tools.error(reason)
end
