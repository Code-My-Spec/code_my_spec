defmodule CodeMySpec.Requirements.PersonasChecker do
  @moduledoc """
  Delegate checker for the `personas_complete` requirement on `project_graph`.

  Satisfied when **every** persona in the active project has:

    * A `personas` row (always true for anything list returns — proof by construction)
    * `.code_my_spec/personas/<slug>/summary.md` that validates as `persona_summary`
    * `.code_my_spec/personas/<slug>/sources.md` with one well-formed entry per line

  Personas are project-scoped. Story linkage is enforced by the Three Amigos
  flow later, not here.

  A249095 briefly relaxed this to "at least one persona researched," reasoning
  that a bare DB stub sitting beside a fully-researched persona shouldn't hold
  the requirement shut forever. That traded one problem for a worse one: an
  agent that created a lightweight persona during Three Amigos (`create_persona`,
  identity + metadata only, no research) got no signal that research was still
  owed, because some *other* persona on the project already had it — story
  559/criterion 5888 is exactly this case. A persona with no research on disk
  is unfinished work regardless of what else exists on the project, so an
  unresearched stub keeping the requirement open is the requirement doing its
  job, not a bug to route around. The stub still needs a name, not a pass.

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

        gaps =
          personas
          |> Enum.map(&check_persona(by_path, &1))
          |> Enum.reject(&(&1 == :ok))

        verdict(gaps)
    end
  end

  def complete?(%Scope{}, _entity) do
    {false, %{reason: "No active project in scope — cannot check personas."}}
  end

  defp verdict([]), do: {true, %{status: "all personas complete"}}
  defp verdict(gaps), do: {false, %{reason: format_gaps(gaps)}}

  # Every checkout of the project, not just the caller's.
  #
  # A persona is project-scoped — `Personas.list_personas/1` above reads them
  # that way — so its artifact is too. Which tree it was written in says nothing
  # about whether the project's personas are researched, and scoping the lookup
  # to one checkout made correct work invisible: a file present, valid and
  # already scanned, reported as missing because the caller's scope named a
  # different root.
  #
  # When several copies hold the same path, the valid one wins. Any checkout
  # having a good version means the artifact exists; letting map ordering decide
  # would make the verdict depend on which row came back first.
  defp synced_persona_files(scope) do
    scope
    |> Files.list_project_files()
    |> Enum.filter(&(&1.role in [:persona_summary, :persona_sources]))
    |> Enum.reduce(%{}, fn file, acc -> Map.update(acc, file.path, file, &better_of(&1, file)) end)
  end

  defp better_of(%FileRecord{valid: true} = kept, _other), do: kept
  defp better_of(_kept, %FileRecord{} = other), do: other

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
