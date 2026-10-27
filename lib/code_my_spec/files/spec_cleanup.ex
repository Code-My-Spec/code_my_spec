defmodule CodeMySpec.Files.SpecCleanup do
  @moduledoc """
  Which spex on the caller's working copy cover nothing: the number its `spex`
  call names is retired or unknown (`Files.SpecBinding`).

  Retiring changes records only; it never deletes a file. A spex is a tracked
  file, and removing it is ordinary work through a copy: the agent deletes it
  in its own checkout and commits. Deleted for it, the files went from whatever
  checkout the retiring agent worked in, which for the product agent was main's:
  the uncommitted deletions refused every sync of main after them (dea00db7).

  So retiring answers with this list, and the agent removes them. Nothing here
  is inferred from filenames or obsolete ids: only the number the file names.
  """

  import Ecto.Query

  alias CodeMySpec.Files.File
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias CodeMySpec.Users.Scope

  @type orphan :: %{path: String.t(), criterion_number: pos_integer()}

  @doc "Every spex on the caller's copy whose number is not a live criterion."
  @spec orphans(Scope.t()) :: [orphan()]
  def orphans(%Scope{} = scope) do
    rows = spex_rows(scope)
    numbers = rows |> Enum.map(& &1.criterion_number) |> Enum.uniq()

    live =
      scope
      |> AcceptanceCriteria.list_criteria_by_number(numbers)
      |> Enum.filter(&is_nil(&1.retired_at))
      |> MapSet.new(& &1.number)

    for file <- rows,
        not MapSet.member?(live, file.criterion_number),
        do: %{path: file.path, criterion_number: file.criterion_number}
  end

  @doc "What a tool tells the agent about `orphans`: which files to remove, and how."
  @spec report([orphan()]) :: String.t()
  def report([]), do: "No spex on your working copy is left covering nothing."

  def report(orphans) do
    "These spex name a criterion that is not live, so they cover nothing. Delete " <>
      "each in your working copy and commit:\n" <>
      Enum.map_join(orphans, "\n", &"- #{&1.path} (criterion #{&1.criterion_number})")
  end

  defp spex_rows(%Scope{active_project_id: project_id, active_working_copy_id: copy_id})
       when is_binary(project_id) and is_binary(copy_id) do
    Repo.all(
      from f in File,
        where:
          f.project_id == ^project_id and f.working_copy_id == ^copy_id and
            f.role == :bdd_spec and not is_nil(f.criterion_number),
        order_by: [asc: f.criterion_number, asc: f.path]
    )
  end

  defp spex_rows(_scope), do: []
end
