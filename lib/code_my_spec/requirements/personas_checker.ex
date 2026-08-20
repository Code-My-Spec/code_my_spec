defmodule CodeMySpec.Requirements.PersonasChecker do
  @moduledoc """
  Delegate checker for the `personas_complete` requirement on `project_graph`.

  Satisfied by **at least one** persona in the active project having:

    * A `personas` row (always true for anything list returns — proof by construction)
    * `.code_my_spec/personas/<slug>/summary.md` that validates as `persona_summary`
    * `.code_my_spec/personas/<slug>/sources.md` with one well-formed entry per line

  Personas are project-scoped. Story linkage is enforced by the Three Amigos
  flow later, not here — `personas_complete` only certifies that the project
  has at least one persona with research on disk.

  This paragraph and the list above used to disagree with each other, and the
  code implemented the list: every persona had to be complete, so one bare stub
  held the requirement shut while a fully researched persona sat beside it. The
  sentence was the contract — it is what the requirement's own description tells
  an agent — so the code matches it now, and personas without research are
  reported in the status rather than blocking.

  ## Decided at sync, read here

  This used to read and validate both files itself, through `scope.environment`.
  On the light harness there is no environment — the server holds no working
  copy — so it answered "Environment is not available" no matter what the agent
  wrote. One wrote the research, watched it sync, and was still told it could
  not be verified.

  The validation now runs in `Files.Scanner` on the machine that has the files,
  and lands in `validation_errors` keyed by concern. This reads the verdict.
  Same rules, same messages, no filesystem — the pattern the `Setup.*` steps
  already use.

  One rule was dropped in the move, deliberately: this used to list the
  persona folder and flag any file other than `summary.md`/`sources.md`.
  Unclassified files are never synced, so there is nothing here to see them
  with. Restoring it means giving strays a role of their own. That trade —
  a tidiness rule for a checker that could not return true at all on the
  light harness — is worth making, but it is a loss, not a simplification.

  Returns `{boolean(), map()}` per the checker contract (see `IssuesChecker`).
  """

  alias CodeMySpec.Files
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Personas
  alias CodeMySpec.Users.Scope

  @spec complete?(Scope.t(), term()) :: {boolean(), map()}
  def complete?(%Scope{active_project_id: project_id} = scope, _entity)
      when not is_nil(project_id) do
    case Personas.list_personas(scope) do
      [] ->
        {false,
         %{
           reason: "No personas on this project. Start a persona research session to add one."
         }}

      personas ->
        by_path = synced_persona_files(scope)
        {done, gaps} = Enum.split_with(personas, &(check_persona(by_path, &1) == :ok))

        verdict(done, Enum.map(gaps, &check_persona(by_path, &1)), length(personas))
    end
  end

  def complete?(%Scope{}, _entity) do
    {false, %{reason: "No active project in scope — cannot check personas."}}
  end

  # One complete persona satisfies this, which is what the requirement has
  # always said and not what it did.
  #
  # `gaps == []` required *every* persona on the project to have valid research,
  # so a single bare stub held the requirement shut forever. Measured on Broken
  # Oaths: "Gem-Weary Wes" had a complete record, `summary.md` and `sources.md`
  # written and well-cited; two other personas existed as DB stubs with no files.
  # `get_next_requirement` kept returning `personas_complete`, and an agent that
  # did exactly the documented work — "at least one persona researched" — was
  # told it had not.
  #
  # That is the expensive direction for a gate to be wrong in. Demanding more
  # than the contract says means the work an agent was told to do never opens
  # the gate, and the only way to find out is to read the checker.
  #
  # The stubs are still named. Satisfying quietly would trade one invisible
  # problem for another — the requirement passes and nobody learns that two
  # personas on the project are empty — so the incomplete ones travel in the
  # status, where they are informational rather than blocking.
  defp verdict([], gaps, _total), do: {false, %{reason: format_gaps(gaps)}}

  defp verdict(done, [], _total),
    do: {true, %{status: "#{length(done)} persona(s) complete"}}

  defp verdict(done, gaps, total) do
    {true,
     %{
       status:
         "#{length(done)} of #{total} persona(s) complete — enough to satisfy this " <>
           "requirement. Still without research on disk:\n#{format_gaps(gaps)}"
     }}
  end

  defp synced_persona_files(scope) do
    scope
    |> Files.list_files()
    |> Enum.filter(&(&1.role in [:persona_summary, :persona_sources]))
    |> Map.new(&{&1.path, &1})
  end

  # Returns :ok or {slug, [gap_messages]}
  defp check_persona(by_path, persona) do
    slug = persona.slug

    gaps =
      [
        gap(by_path, Personas.summary_path(slug), "summary", "`summary.md` missing"),
        gap(by_path, Personas.sources_path(slug), "sources", "`sources.md` missing")
      ]
      |> Enum.reject(&is_nil/1)

    case gaps do
      [] -> :ok
      gaps -> {slug, gaps}
    end
  end

  # Not synced at all means the file is not there. Synced with an error against
  # its concern means it is there and wrong, and the message is the one the
  # validator wrote at sync time.
  defp gap(by_path, path, concern, missing_message) do
    case Map.get(by_path, path) do
      nil -> missing_message
      %FileRecord{validation_errors: errors} -> concern_error(errors, concern)
    end
  end

  defp concern_error(%{"errors" => errors}, concern) when is_map(errors),
    do: Map.get(errors, concern)

  defp concern_error(_, _), do: nil

  defp format_gaps(gaps) do
    sections =
      Enum.map(gaps, fn {slug, messages} ->
        bullets = Enum.map_join(messages, "\n", &"  - #{&1}")
        "### #{slug}\n#{bullets}"
      end)

    "Persona research incomplete:\n\n" <> Enum.join(sections, "\n\n")
  end
end
