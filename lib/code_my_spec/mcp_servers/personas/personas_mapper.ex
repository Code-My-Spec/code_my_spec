defmodule CodeMySpec.McpServers.Personas.PersonasMapper do
  @moduledoc """
  Maps persona data to MCP responses. Returns text-only responses and embeds
  identifiers in the summary text so agents can reference them in follow-up
  tool calls. Personas are project-scoped; cross-project access is rejected.
  """

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Formatters

  def persona_response(persona) do
    type_line = "Type: `#{persona.persona_type}` — #{persona_type_note(persona.persona_type)}"

    summary = """
    Persona created: "#{persona.name}" (slug: `#{persona.slug}`, id: `#{persona.id}`)

    #{type_line}

    Next steps:
    - Write `.code_my_spec/personas/#{persona.slug}/summary.md` with required sections (Role, Goals, Pain Points, Context, Decision Drivers, Evidence).
    - Write `.code_my_spec/personas/#{persona.slug}/sources.md` with URL + title + access date per entry.
    - Call `link_persona_to_story` with persona_id `#{persona.id}` and a story_id this persona applies to.
    """

    Response.tool()
    |> Response.text(String.trim(summary))
  end

  defp persona_type_note(:proto),
    do:
      "hypothesis from desk research. Treat all claims as provisional and validate with real users before load-bearing decisions depend on them."

  defp persona_type_note(:qualitative),
    do: "backed by 5–30 coded user interviews. Trustworthy for feature design and prioritization."

  defp persona_type_note(:statistical),
    do: "backed by survey + cluster analysis. Trustworthy for strategic and investment decisions."

  defp persona_type_note(_), do: "unknown tier — check the database schema for valid values."

  def link_response(persona_story) do
    summary =
      "Persona linked: persona_id `#{persona_story.persona_id}` ↔ story_id `#{persona_story.story_id}`."

    Response.tool()
    |> Response.text(summary)
  end

  def unlink_response(persona_id, story_id) do
    summary =
      "Persona unlinked: persona_id `#{persona_id}` ↮ story_id `#{story_id}`."

    Response.tool()
    |> Response.text(summary)
  end

  def update_response(persona) do
    headline = (persona.headline && "\nHeadline: #{persona.headline}") || ""

    summary = """
    Persona updated: "#{persona.name}" (slug: `#{persona.slug}`, id: `#{persona.id}`, type: `#{persona.persona_type}`).#{headline}
    """

    Response.tool()
    |> Response.text(String.trim(summary))
  end

  def delete_response(persona) do
    summary =
      "Persona deleted: \"#{persona.name}\" (slug: `#{persona.slug}`, id: `#{persona.id}`). All `persona_stories` links removed."

    Response.tool()
    |> Response.text(summary)
  end

  def personas_list_response([]) do
    Response.tool()
    |> Response.text(
      "No personas on this project yet. Run a persona research session to create one — " <>
        "see `start_task` with requirement `personas_complete`."
    )
  end

  def personas_list_response(personas) when is_list(personas) do
    lines =
      Enum.map_join(personas, "\n", fn p ->
        headline = (p.headline && " — #{p.headline}") || ""
        "- **#{p.name}** (slug: `#{p.slug}`, id: `#{p.id}`, type: `#{p.persona_type}`)#{headline}"
      end)

    summary = "Personas on this project (#{length(personas)}):\n\n#{lines}"

    Response.tool()
    |> Response.text(summary)
  end

  def validation_error(changeset) do
    Response.tool()
    |> Response.error(Formatters.format_changeset_errors(changeset))
  end

  def error(%Ecto.Changeset{} = changeset), do: validation_error(changeset)

  def error(:not_found) do
    Response.tool()
    |> Response.error("Persona not found on the active project.")
  end

  def error(:cross_project) do
    Response.tool()
    |> Response.error(
      "Cross-project operation rejected. The persona or story does not belong to the active project."
    )
  end

  def error(:missing_active_project) do
    Response.tool()
    |> Response.error(
      "Active project is not set on the scope. " <>
        "Run `init_project` to link your working directory to a project, then retry."
    )
  end

  def error(:no_working_dir) do
    Response.tool()
    |> Response.error(
      "This tool needs the project's working copy, and this request did not name one. " <>
        "The MCP client must send an `X-Harness-Id` header; the id is in .cms_harness.json " <>
        "at the working copy's root, written by `mix cms.harness.onboard`."
    )
  end

  def error(:unauthorized) do
    Response.tool()
    |> Response.error(
      "Scope could not be resolved from the working directory. Confirm the project is initialized (`init_project`) and the local_path on the project record matches your cwd."
    )
  end

  def error(error) when is_atom(error) do
    error |> to_string() |> error()
  end

  def error(error) when is_binary(error) do
    Response.tool()
    |> Response.error(error)
  end
end
