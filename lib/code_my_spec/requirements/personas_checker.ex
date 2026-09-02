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
  agent that created a lightweight persona during Three Amigos (`add_persona`,
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
          |> Enum.map(&check_persona(by_path, scope, &1))
          |> Enum.reject(&(&1 == :ok))

        verdict(gaps)
    end
  end

  def complete?(%Scope{}, _entity) do
    {false, %{reason: "No active project in scope — cannot check personas."}}
  end

  defp verdict([]), do: {true, %{status: "all personas complete"}}
  defp verdict(gaps), do: {false, %{reason: format_gaps(gaps)}}

  defp synced_persona_files(scope) do
    scope
    |> Files.list_files()
    |> Enum.filter(&(&1.role in [:persona_summary, :persona_sources]))
    |> Map.new(&{&1.path, &1})
  end

  # Returns :ok or {slug, [gap_messages]}
  defp check_persona(by_path, scope, persona) do
    slug = persona.slug
    where = looked_in(scope)

    gaps =
      [
        gap(by_path, Personas.summary_path(slug), "summary", "`summary.md` missing" <> where),
        gap(by_path, Personas.sources_path(slug), "sources", "`sources.md` missing" <> where)
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

  # Which checkout was searched, named in the refusal.
  #
  # `Files.list_files/1` is scoped to the caller's working copy, so a file
  # written in one checkout is invisible to a scope bound to another — and
  # "`summary.md` missing" then describes a file that exists, is valid, and has
  # already been scanned. That wording sent an agent back to rewrite correct
  # artifacts three times before anyone thought to ask *where* the checker was
  # looking.
  #
  # The mismatch is not exotic. The MCP mount sends `X-Harness-Id` from
  # `CMS_HARNESS_ID` in the environment, and a session that inherited that
  # variable from one checkout while working in another carries the first one's
  # id and writes the second one's files. Naming the root turns a silent
  # contradiction into a one-line diagnosis.
  defp looked_in(%Scope{active_working_copy_id: nil}), do: ""

  defp looked_in(%Scope{active_working_copy_id: id}) do
    case CodeMySpec.WorkingCopies.fetch(id) do
      {:ok, %{root: root}} when is_binary(root) -> " from #{root}"
      _ -> ""
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
